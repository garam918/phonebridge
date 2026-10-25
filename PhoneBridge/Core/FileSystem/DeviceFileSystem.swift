import Foundation

/// Device-side file operations the UI and the TransferManager depend on.
/// Real devices are served by `MTPDeviceFileSystem` (through DeviceBroker's
/// session), the demo device by `MockDeviceFileSystem`. The UI never sees libmtp.
///
/// Every method addresses objects by `FileItemID`; ids are only valid for the
/// `generation` that produced them.
protocol DeviceFileSystem: AnyObject, Sendable {
    var deviceID: DeviceID { get }
    /// True for the virtual demo device. The UI labels mock data explicitly.
    var isMock: Bool { get }
    var generation: UInt64 { get }
    var capabilities: FileSystemCapabilities { get }

    func storages() async throws(DeviceError) -> [StorageInfo]
    func contents(of folder: FileItemID) async throws(DeviceError) -> [FileItem]
    /// How many objects the device has in `folder`, counted from its handle
    /// list. Unlike `contents`, this includes objects whose metadata could not
    /// be read, so 0 really means empty (checked before deleting a folder that
    /// Android would delete recursively).
    func childCount(of folder: FileItemID) async throws(DeviceError) -> Int
    func item(_ id: FileItemID) async throws(DeviceError) -> FileItem

    /// Writes the object's bytes to `fileURL` (created or truncated).
    func download(_ id: FileItemID, to fileURL: URL, progress: TransferProgress) async throws(DeviceError)
    /// Creates a new object `name` in `folder` from the local file.
    func upload(from fileURL: URL, size: UInt64, named name: String, into folder: FileItemID, modified: Date?,
                progress: TransferProgress) async throws(DeviceError) -> FileItem
    func createFolder(named name: String, in folder: FileItemID) async throws(DeviceError) -> FileItem
    func rename(_ id: FileItemID, to name: String) async throws(DeviceError) -> FileItem
    /// Deletes a single object. Callers empty folders first: Android deletes a
    /// folder with everything still in it.
    func delete(_ id: FileItemID) async throws(DeviceError)
    /// Native move; check `capabilities.canMoveNatively` first.
    func move(_ id: FileItemID, to folder: FileItemID) async throws(DeviceError) -> FileItem
    /// Native copy; check `capabilities.canCopyNatively` first.
    func copy(_ id: FileItemID, to folder: FileItemID) async throws(DeviceError) -> FileItem
    func thumbnail(_ id: FileItemID) async throws(DeviceError) -> Data
    /// Reads `length` bytes at `offset`; requires `capabilities.canReadPartially`.
    /// Returns fewer bytes at end of file.
    func read(_ id: FileItemID, offset: UInt64, length: Int) async throws(DeviceError) -> Data
}

/// Browsing and editing backed by an MTP session. Holds the session, not the
/// broker: once the broker closes the session (unplug, retry), every call
/// fails with `.disconnected` instead of touching a dead handle.
final class MTPDeviceFileSystem: DeviceFileSystem {
    let deviceID: DeviceID
    let generation: UInt64
    let isMock = false
    let capabilities: FileSystemCapabilities
    private let session: MTPDeviceSession

    init(deviceID: DeviceID, generation: UInt64, session: MTPDeviceSession,
         capabilities: FileSystemCapabilities = .readOnly) {
        self.deviceID = deviceID
        self.generation = generation
        self.session = session
        self.capabilities = capabilities
    }

    func storages() async throws(DeviceError) -> [StorageInfo] {
        try await session.storages()
    }

    func contents(of folder: FileItemID) async throws(DeviceError) -> [FileItem] {
        let objects = try await session.listFolder(storageID: folder.storageID, parentID: folder.objectID)
        return objects.map(fileItem)
    }

    func childCount(of folder: FileItemID) async throws(DeviceError) -> Int {
        try await session.childCount(storageID: folder.storageID, parentID: folder.objectID)
    }

    func item(_ id: FileItemID) async throws(DeviceError) -> FileItem {
        guard !id.isStorageRoot else { throw .objectNotFound }
        return fileItem(try await session.objectInfo(objectID: id.objectID))
    }

    func download(_ id: FileItemID, to fileURL: URL, progress: TransferProgress) async throws(DeviceError) {
        let fd = try LocalFileIO.openForWriting(fileURL)
        defer { close(fd) }
        if capabilities.canReadPartially, let size = try await item(id).size, size >= Self.chunkedDownloadThreshold {
            try await downloadInChunks(id, size: size, fd: fd, url: fileURL, progress: progress)
        } else {
            try await session.download(objectID: id.objectID, to: fd, progress: progress)
        }
        guard fsync(fd) == 0 else { throw LocalFileIO.mapErrno(errno, url: fileURL, writing: true) }
    }

    /// Downloads at least this large go in pieces when the device allows it.
    static let chunkedDownloadThreshold: UInt64 = 32 << 20
    static let downloadChunkSize: UInt32 = 16 << 20

    /// GetObject holds the device for the whole file. GetPartialObject pieces
    /// are separate jobs on the session queue, so browsing, thumbnails and
    /// Finder reads get in between (like chunked uploads, D40). If a piece
    /// fails for another reason than an unplug or a cancel (for example a
    /// device limited to 32-bit offsets), the file is fetched again in one go.
    private func downloadInChunks(_ id: FileItemID, size: UInt64, fd: Int32, url: URL,
                                  progress: TransferProgress) async throws(DeviceError) {
        var received: UInt64 = 0
        progress.update(completed: 0, total: size)
        do throws(DeviceError) {
            while received < size {
                if progress.isCancelled { throw .cancelled }
                let length = UInt32(min(UInt64(Self.downloadChunkSize), size - received))
                let data = try await session.readPartial(objectID: id.objectID, offset: received, length: length)
                guard !data.isEmpty else { throw .verificationFailed(expected: size, actual: received) }
                try LocalFileIO.writeAll(fd, data, url: url)
                received += UInt64(data.count)
                progress.update(completed: received, total: size)
            }
        } catch {
            switch error {
            case .cancelled, .disconnected, .usbError, .verificationFailed: throw error
            default:
                if progress.isCancelled { throw .cancelled }
                Log.mtp.notice("chunked download stopped at \(received) of \(size) bytes (\(error.localizationKey, privacy: .public)); downloading in one go")
                guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else { throw LocalFileIO.mapErrno(errno, url: url, writing: true) }
                try await session.download(objectID: id.objectID, to: fd, progress: progress)
            }
        }
    }

    /// Uploads at least this large go in pieces when the device allows it.
    static let chunkedUploadThreshold: UInt64 = 32 << 20
    static let uploadChunkSize = 16 << 20

    func upload(from fileURL: URL, size: UInt64, named rawName: String, into folder: FileItemID, modified: Date?,
                progress: TransferProgress) async throws(DeviceError) -> FileItem {
        let name = FileNameRules.deviceForm(rawName)
        let fd = try LocalFileIO.openForReading(fileURL)
        defer { close(fd) }
        guard capabilities.canUploadInChunks, size >= Self.chunkedUploadThreshold else {
            let newID = try await session.upload(from: fd, name: name, size: size, modified: modified,
                                                 storageID: folder.storageID, parentID: folder.objectID, progress: progress)
            return try await item(FileItemID(deviceID: deviceID, storageID: folder.storageID, objectID: newID))
        }
        return try await uploadInChunks(fd: fd, url: fileURL, size: size, named: name, into: folder, modified: modified,
                                        progress: progress)
    }

    /// One SendObject transaction holds the device for the whole file (MTP
    /// serves one request at a time). Here the object is created empty and
    /// filled with SendPartialObject pieces, each a separate job on the
    /// session queue, so browsing and reads get in between (review 2026-10-22).
    /// A failure leaves a partial object under the caller's (staging) name;
    /// the caller removes it as for any failed upload.
    private func uploadInChunks(fd: Int32, url: URL, size: UInt64, named name: String, into folder: FileItemID, modified: Date?,
                                progress: TransferProgress) async throws(DeviceError) -> FileItem {
        let empty = try LocalFileIO.openForReading(URL(fileURLWithPath: "/dev/null"))
        defer { close(empty) }
        let objectID = try await session.upload(from: empty, name: name, size: 0, modified: modified, storageID: folder.storageID,
                                                parentID: folder.objectID, progress: TransferProgress())
        try await session.beginEdit(objectID: objectID)
        var sent: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: Self.uploadChunkSize)
        progress.update(completed: 0, total: size)
        do throws(DeviceError) {
            while sent < size {
                if progress.isCancelled { throw .cancelled }
                let wanted = Int(min(UInt64(buffer.count), size - sent))
                let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, wanted, off_t(sent)) }
                if count < 0 { throw LocalFileIO.mapErrno(errno, url: url, writing: false) }
                if count == 0 { break } // source shrank; the caller's size check catches it
                try await session.sendPartial(objectID: objectID, offset: sent, data: Data(buffer[0..<count]))
                sent += UInt64(count)
                progress.update(completed: sent, total: size)
            }
            try await session.endEdit(objectID: objectID)
        } catch {
            try? await session.endEdit(objectID: objectID)
            throw error
        }
        let uploaded = try await item(FileItemID(deviceID: deviceID, storageID: folder.storageID, objectID: objectID))
        Log.mtp.info("chunked upload of \(sent) bytes; device reports \(uploaded.size ?? 0)")
        return uploaded
    }

    func createFolder(named name: String, in folder: FileItemID) async throws(DeviceError) -> FileItem {
        let newID = try await session.createFolder(name: FileNameRules.deviceForm(name), storageID: folder.storageID, parentID: folder.objectID)
        return try await item(FileItemID(deviceID: deviceID, storageID: folder.storageID, objectID: newID))
    }

    func rename(_ id: FileItemID, to name: String) async throws(DeviceError) -> FileItem {
        guard capabilities.canRename else { throw .unsupportedOperation }
        try await session.rename(objectID: id.objectID, to: FileNameRules.deviceForm(name))
        return try await item(id)
    }

    func delete(_ id: FileItemID) async throws(DeviceError) {
        try await session.delete(objectID: id.objectID)
    }

    func move(_ id: FileItemID, to folder: FileItemID) async throws(DeviceError) -> FileItem {
        guard capabilities.canMoveNatively else { throw .unsupportedOperation }
        try await session.move(objectID: id.objectID, storageID: folder.storageID, parentID: folder.objectID)
        // MTP keeps the handle on move; re-read for the new parent/storage.
        return try await item(FileItemID(deviceID: deviceID, storageID: folder.storageID, objectID: id.objectID))
    }

    func copy(_ id: FileItemID, to folder: FileItemID) async throws(DeviceError) -> FileItem {
        guard capabilities.canCopyNatively else { throw .unsupportedOperation }
        let source = try await item(id)
        let before = Set(try await contents(of: folder).map(\.id))
        try await session.copy(objectID: id.objectID, storageID: folder.storageID, parentID: folder.objectID)
        // CopyObject's new handle is not surfaced by libmtp; find it by name.
        guard let copied = try await contents(of: folder).first(where: { !before.contains($0.id) && $0.name == source.name }) else {
            throw .objectNotFound
        }
        return copied
    }

    func thumbnail(_ id: FileItemID) async throws(DeviceError) -> Data {
        try await session.thumbnail(objectID: id.objectID)
    }

    func read(_ id: FileItemID, offset: UInt64, length: Int) async throws(DeviceError) -> Data {
        guard capabilities.canReadPartially else { throw .unsupportedOperation }
        let clamped = UInt32(clamping: max(0, length))
        guard clamped > 0 else { return Data() }
        return try await session.readPartial(objectID: id.objectID, offset: offset, length: clamped)
    }

    private func fileItem(_ object: MTPObjectInfo) -> FileItem {
        FileItem(
            id: FileItemID(deviceID: deviceID, storageID: object.storageID, objectID: object.objectID),
            // Device names become Mac path components and Finder entries.
            name: FileNameRules.singleComponent(object.name),
            isFolder: object.isFolder,
            size: object.isFolder ? nil : object.size,
            modified: object.modified
        )
    }
}
