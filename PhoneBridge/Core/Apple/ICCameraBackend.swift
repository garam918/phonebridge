import Foundation
import ImageCaptureCore

/// `CameraBackend` on an `ICCameraDevice` (an iPhone/iPad over USB, D75).
/// Image Capture objects are only touched on the main actor; their block
/// callbacks arrive on any queue and are bridged with continuations.
final class ICCameraBackend: CameraBackend, @unchecked Sendable {
    @MainActor private weak var device: ICCameraDevice?
    /// Items of the last catalog by id (PTP object handle when there is one).
    @MainActor private var items: [UInt32: ICCameraItem] = [:]
    @MainActor private var syntheticIDs: [ObjectIdentifier: UInt32] = [:]
    @MainActor private var nextSyntheticID: UInt32 = 0x8000_0000

    @MainActor
    init(device: ICCameraDevice) {
        self.device = device
    }

    func catalog() async throws(DeviceError) -> [CameraEntry] {
        try await MainActor.run { () -> Result<[CameraEntry], DeviceError> in
            guard let device else { return .failure(.disconnected) }
            if device.isAccessRestrictedAppleDevice { return .failure(.accessDenied) }
            var entries: [CameraEntry] = []
            var found: [UInt32: ICCameraItem] = [:]
            @MainActor func walk(_ list: [ICCameraItem]?, parent: UInt32) {
                for item in list ?? [] {
                    let id = identifier(of: item)
                    found[id] = item
                    let folder = item as? ICCameraFolder
                    let file = item as? ICCameraFile
                    entries.append(CameraEntry(id: id, parentID: parent, name: item.name ?? "",
                                               isFolder: folder != nil,
                                               size: file.map { UInt64(max(0, $0.fileSize)) },
                                               modified: item.creationDate ?? item.modificationDate))
                    if let folder { walk(folder.contents, parent: id) }
                }
            }
            walk(device.contents, parent: FileItemID.rootObjectID)
            items = found
            return .success(entries)
        }.get()
    }

    func read(_ id: UInt32, offset: UInt64, length: Int) async throws(DeviceError) -> Data {
        let file = try await cameraFile(id)
        let result: Result<Data, DeviceError> = await withCheckedContinuation { continuation in
            file.value.requestReadData(atOffset: off_t(offset), length: off_t(length)) { data, error in
                if let error {
                    continuation.resume(returning: .failure(Self.map(error)))
                } else {
                    continuation.resume(returning: .success(data ?? Data()))
                }
            }
        }
        return try result.get()
    }

    func thumbnail(_ id: UInt32) async throws(DeviceError) -> Data {
        let file = try await cameraFile(id)
        let result: Result<Data, DeviceError> = await withCheckedContinuation { continuation in
            file.value.requestThumbnailData(options: nil) { data, error in
                if let data, error == nil {
                    continuation.resume(returning: .success(data))
                } else {
                    continuation.resume(returning: .failure(error.map(Self.map) ?? .objectNotFound))
                }
            }
        }
        return try result.get()
    }

    func delete(_ ids: [UInt32]) async throws(DeviceError) {
        let target = try await MainActor.run { () -> Result<Unchecked<(ICCameraDevice, [ICCameraItem])>, DeviceError> in
            guard let device else { return .failure(.disconnected) }
            let files = ids.compactMap { items[$0] }
            guard files.count == ids.count else { return .failure(.objectNotFound) }
            return .success(Unchecked((device, files)))
        }.get()
        let result: Result<Void, DeviceError> = await withCheckedContinuation { continuation in
            Task { @MainActor in
                _ = target.value.0.requestDeleteFiles(target.value.1, deleteFailed: { _ in }) { _, error in
                    continuation.resume(returning: error.map { .failure(Self.map($0)) } ?? .success(()))
                }
            }
        }
        try result.get()
    }

    // MARK: - Helpers

    @MainActor
    private func identifier(of item: ICCameraItem) -> UInt32 {
        if item.ptpObjectHandle != 0, item.ptpObjectHandle != FileItemID.rootObjectID { return item.ptpObjectHandle }
        let key = ObjectIdentifier(item)
        if let known = syntheticIDs[key] { return known }
        nextSyntheticID += 1
        syntheticIDs[key] = nextSyntheticID
        return nextSyntheticID
    }

    private func cameraFile(_ id: UInt32) async throws(DeviceError) -> Unchecked<ICCameraFile> {
        if let file = await MainActor.run(body: { (items[id] as? ICCameraFile).map(Unchecked.init) }) { return file }
        _ = try await catalog()
        guard let file = await MainActor.run(body: { (items[id] as? ICCameraFile).map(Unchecked.init) }) else { throw .objectNotFound }
        return file
    }

    static func map(_ error: any Error) -> DeviceError {
        let nsError = error as NSError
        // ICReturnSessionNotOpened (-9958), ICLegacyReturnCodeDeviceNotOpenErr (-9902): the device went away.
        if nsError.domain == ICErrorDomain, nsError.code == -9958 || nsError.code == -9902 {
            return .disconnected
        }
        return .protocolError(code: Int32(truncatingIfNeeded: nsError.code), detail: nsError.domain)
    }
}

/// Carries an Image Capture object across the continuation boundary; it is
/// only used by the block-based calls, which Image Capture allows from any queue.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
