import Foundation

/// Owns one MTP connection and serializes every operation on it.
///
/// The actor runs on its own serial dispatch queue (custom executor), so the
/// blocking libmtp calls never execute on the main thread nor on Swift's
/// cooperative pool, and two operations on the same device never overlap.
/// Only `DeviceBroker` creates sessions; a closed session stays closed and
/// every later call throws `.disconnected`, which is how stale file-system
/// handles fail safely after an unplug.
actor MTPDeviceSession {
    nonisolated let target: MTPTarget
    nonisolated let label: String

    private let queue: DispatchSerialQueue
    private let backend: any MTPBackend
    private var connection: (any MTPConnection)?
    private var isClosed = false

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(target: MTPTarget, backend: any MTPBackend, label: String) {
        self.target = target
        self.backend = backend
        self.label = label
        queue = DispatchSerialQueue(label: "com.phonebridge.mtp.\(label)", qos: .userInitiated)
    }

    var isOpen: Bool { connection != nil }

    /// Claim test + session open. Throws `.deviceBusy` when another process
    /// holds the interface, before libmtp gets a chance to reset the device.
    func open() throws(DeviceError) -> (info: MTPDeviceInfo, capabilities: MTPCapabilities) {
        guard !isClosed else { throw .disconnected }
        if let existing = connection {
            existing.close()
            connection = nil
        }
        switch backend.preflight(target) {
        case .available: break
        case .busy: throw .deviceBusy(owner: nil)
        case .noMTPInterface: throw .noMTPInterface
        case .failed(let error): throw error
        }
        let opened = try backend.open(target)
        connection = opened
        let info = opened.deviceInfo()
        let capabilities = opened.capabilities()
        Log.mtp.info("[\(self.label, privacy: .private(mask: .hash))] session open: \(info.manufacturer ?? "?", privacy: .public) \(info.model ?? "?", privacy: .public) caps=\(capabilities.rawValue)")
        return (info, capabilities)
    }

    func storages() throws(DeviceError) -> [StorageInfo] {
        try requireConnection().storages()
    }

    func listFolder(storageID: UInt32, parentID: UInt32) throws(DeviceError) -> [MTPObjectInfo] {
        try requireConnection().listFolder(storageID: storageID, parentID: parentID)
    }

    func childCount(storageID: UInt32, parentID: UInt32) throws(DeviceError) -> Int {
        try requireConnection().childCount(storageID: storageID, parentID: parentID)
    }

    func objectInfo(objectID: UInt32) throws(DeviceError) -> MTPObjectInfo {
        try requireConnection().objectInfo(objectID: objectID)
    }

    /// Blocks this device's queue for the whole transfer; other operations on
    /// the same device wait (MTP allows one transaction at a time anyway).
    func download(objectID: UInt32, to fd: Int32, progress: TransferProgress) throws(DeviceError) {
        try requireConnection().download(objectID: objectID, to: fd, progress: progress)
    }

    func upload(from fd: Int32, name: String, size: UInt64, modified: Date?, storageID: UInt32, parentID: UInt32,
                progress: TransferProgress) throws(DeviceError) -> UInt32 {
        try requireConnection().upload(from: fd, name: name, size: size, modified: modified, storageID: storageID,
                                       parentID: parentID, progress: progress)
    }

    func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws(DeviceError) -> UInt32 {
        try requireConnection().createFolder(name: name, storageID: storageID, parentID: parentID)
    }

    func rename(objectID: UInt32, to name: String) throws(DeviceError) {
        try requireConnection().rename(objectID: objectID, to: name)
    }

    func delete(objectID: UInt32) throws(DeviceError) {
        try requireConnection().delete(objectID: objectID)
    }

    func move(objectID: UInt32, storageID: UInt32, parentID: UInt32) throws(DeviceError) {
        try requireConnection().move(objectID: objectID, storageID: storageID, parentID: parentID)
    }

    func copy(objectID: UInt32, storageID: UInt32, parentID: UInt32) throws(DeviceError) {
        try requireConnection().copy(objectID: objectID, storageID: storageID, parentID: parentID)
    }

    func thumbnail(objectID: UInt32) throws(DeviceError) -> Data {
        try requireConnection().thumbnail(objectID: objectID)
    }

    func readPartial(objectID: UInt32, offset: UInt64, length: UInt32) throws(DeviceError) -> Data {
        try requireConnection().readPartial(objectID: objectID, offset: offset, length: length)
    }

    // Chunked upload: each call is its own job on this queue, so listings and
    // reads queued meanwhile run between the pieces of a large upload.

    func beginEdit(objectID: UInt32) throws(DeviceError) {
        try requireConnection().beginEdit(objectID: objectID)
    }

    func sendPartial(objectID: UInt32, offset: UInt64, data: Data) throws(DeviceError) {
        try requireConnection().sendPartial(objectID: objectID, offset: offset, data: data)
    }

    func endEdit(objectID: UInt32) throws(DeviceError) {
        try requireConnection().endEdit(objectID: objectID)
    }

    /// Ends the MTP session. Safe after the cable was pulled: libmtp's
    /// CloseSession simply fails and the handle is released anyway.
    func close() {
        isClosed = true
        guard let existing = connection else { return }
        connection = nil
        existing.close()
        Log.mtp.info("[\(self.label, privacy: .private(mask: .hash))] session closed")
    }

    private func requireConnection() throws(DeviceError) -> any MTPConnection {
        guard let connection, !isClosed else { throw .disconnected }
        return connection
    }
}
