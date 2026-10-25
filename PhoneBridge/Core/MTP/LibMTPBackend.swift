import Foundation

/// `MTPBackend` on top of the PBMTPBridge C facade (libmtp + libusb).
struct LibMTPBackend: MTPBackend {
    init() {
        pb_initialize()
    }

    static var libmtpVersion: String {
        String(cString: pb_libmtp_version())
    }

    /// Diagnostics: how many USB devices libusb sees from inside the sandbox.
    static func visibleUSBDeviceCount() -> Int32 {
        pb_usb_device_count()
    }

    func preflight(_ target: MTPTarget) -> MTPPreflightResult {
        var error = pb_error()
        let status = pb_usb_preflight(target.bus, target.address, &error)
        let message = String(cString: pb_error_message(&error))
        switch status {
        case PB_STATUS_OK:
            return .available
        case PB_STATUS_BUSY:
            Log.mtp.notice("preflight busy: \(message, privacy: .public)")
            return .busy
        case PB_STATUS_NO_INTERFACE:
            return .noMTPInterface
        default:
            Log.mtp.error("preflight failed: \(message, privacy: .public)")
            let mapped = MTPErrorMapper.map(rawStatus: Int32(status.rawValue), nativeCode: error.native_code, message: message)
            return .failed(mapped ?? .unknown(detail: message))
        }
    }

    func open(_ target: MTPTarget) throws(DeviceError) -> any MTPConnection {
        var error = pb_error()
        guard let device = pb_open(target.bus, target.address, target.vendorID, target.productID, &error) else {
            let message = String(cString: pb_error_message(&error))
            Log.mtp.error("open failed: \(message, privacy: .public)")
            throw MTPErrorMapper.map(rawStatus: Int32(error.status.rawValue), nativeCode: error.native_code, message: message)
                ?? .sessionOpenFailed(detail: message)
        }
        return LibMTPConnection(device: device)
    }
}

final class LibMTPConnection: MTPConnection {
    private var device: OpaquePointer?

    init(device: OpaquePointer) {
        self.device = device
    }

    deinit {
        close()
    }

    func deviceInfo() -> MTPDeviceInfo {
        var info = pb_device_info()
        pb_get_device_info(device, &info)
        defer { pb_free_device_info(&info) }
        return MTPDeviceInfo(
            manufacturer: Self.string(info.manufacturer),
            model: Self.string(info.model),
            serialNumber: Self.string(info.serial_number),
            deviceVersion: Self.string(info.device_version),
            friendlyName: Self.string(info.friendly_name),
            batteryLevel: info.battery_percent >= 0 ? Int(info.battery_percent) : nil
        )
    }

    func storages() throws(DeviceError) -> [StorageInfo] {
        guard let device else { throw .disconnected }
        var error = pb_error()
        var pointer: UnsafeMutablePointer<pb_storage>?
        var count = 0
        let status = pb_list_storages(device, &pointer, &count, &error)
        defer { pb_free_storages(pointer, count) }
        try Self.check(status, error)
        let buffer = UnsafeBufferPointer(start: pointer, count: count)
        return buffer.map { storage in
            StorageInfo(
                mtpStorageID: storage.storage_id,
                description: Self.string(storage.description),
                volumeIdentifier: Self.string(storage.volume_identifier),
                storageType: storage.storage_type,
                accessCapability: storage.access_capability,
                capacity: storage.max_capacity,
                freeSpace: storage.free_space
            )
        }
    }

    func listFolder(storageID: UInt32, parentID: UInt32) throws(DeviceError) -> [MTPObjectInfo] {
        guard let device else { throw .disconnected }
        var error = pb_error()
        var pointer: UnsafeMutablePointer<pb_object>?
        var count = 0
        let status = pb_list_folder(device, storageID, parentID, &pointer, &count, &error)
        defer { pb_free_objects(pointer, count) }
        try Self.check(status, error)
        return UnsafeBufferPointer(start: pointer, count: count).map(Self.objectInfo)
    }

    func childCount(storageID: UInt32, parentID: UInt32) throws(DeviceError) -> Int {
        let device = try requireDevice()
        var error = pb_error()
        var count: UInt32 = 0
        try Self.check(pb_count_children(device, storageID, parentID, &count, &error), error)
        return Int(count)
    }

    func capabilities() -> MTPCapabilities {
        guard let device else { return [] }
        return MTPCapabilities(rawValue: pb_capabilities(device))
    }

    func objectInfo(objectID: UInt32) throws(DeviceError) -> MTPObjectInfo {
        let device = try requireDevice()
        var error = pb_error()
        var object = pb_object()
        let status = pb_get_object(device, objectID, &object, &error)
        defer { pb_free_object_fields(&object) }
        try Self.check(status, error)
        return Self.objectInfo(object)
    }

    func download(objectID: UInt32, to fd: Int32, progress: TransferProgress) throws(DeviceError) {
        let device = try requireDevice()
        var error = pb_error()
        let context = Unmanaged.passUnretained(progress).toOpaque()
        let status = withExtendedLifetime(progress) {
            pb_download_to_fd(device, objectID, fd, Self.progressCallback, context, &error)
        }
        if progress.isCancelled { throw .cancelled }
        try Self.check(status, error)
    }

    func upload(from fd: Int32, name: String, size: UInt64, modified: Date?, storageID: UInt32, parentID: UInt32,
                progress: TransferProgress) throws(DeviceError) -> UInt32 {
        let device = try requireDevice()
        var error = pb_error()
        var newID: UInt32 = 0
        let context = Unmanaged.passUnretained(progress).toOpaque()
        let timestamp = Int64(modified?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
        let status = withExtendedLifetime(progress) {
            pb_upload_from_fd(device, fd, name, size, timestamp, storageID, parentID,
                              Self.progressCallback, context, &newID, &error)
        }
        if progress.isCancelled { throw .cancelled }
        try Self.check(status, error)
        return newID
    }

    func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws(DeviceError) -> UInt32 {
        let device = try requireDevice()
        var error = pb_error()
        var newID: UInt32 = 0
        try Self.check(pb_create_folder(device, name, storageID, parentID, &newID, &error), error)
        return newID
    }

    func rename(objectID: UInt32, to name: String) throws(DeviceError) {
        let device = try requireDevice()
        var error = pb_error()
        try Self.check(pb_rename(device, objectID, name, &error), error)
    }

    func delete(objectID: UInt32) throws(DeviceError) {
        let device = try requireDevice()
        var error = pb_error()
        try Self.check(pb_delete(device, objectID, &error), error)
    }

    func move(objectID: UInt32, storageID: UInt32, parentID: UInt32) throws(DeviceError) {
        let device = try requireDevice()
        var error = pb_error()
        try Self.check(pb_move(device, objectID, storageID, parentID, &error), error)
    }

    func copy(objectID: UInt32, storageID: UInt32, parentID: UInt32) throws(DeviceError) {
        let device = try requireDevice()
        var error = pb_error()
        try Self.check(pb_copy(device, objectID, storageID, parentID, &error), error)
    }

    func thumbnail(objectID: UInt32) throws(DeviceError) -> Data {
        let device = try requireDevice()
        var error = pb_error()
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        let status = pb_get_thumbnail(device, objectID, &bytes, &count, &error)
        defer { pb_free_buffer(bytes) }
        try Self.check(status, error)
        guard let bytes, count > 0 else { throw .objectNotFound }
        return Data(bytes: bytes, count: count)
    }

    func readPartial(objectID: UInt32, offset: UInt64, length: UInt32) throws(DeviceError) -> Data {
        let device = try requireDevice()
        var error = pb_error()
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        let status = pb_read_partial(device, objectID, offset, length, &bytes, &count, &error)
        defer { pb_free_buffer(bytes) }
        try Self.check(status, error)
        guard let bytes, count > 0 else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func beginEdit(objectID: UInt32) throws(DeviceError) {
        let device = try requireDevice()
        var error = pb_error()
        try Self.check(pb_begin_edit(device, objectID, &error), error)
    }

    func sendPartial(objectID: UInt32, offset: UInt64, data: Data) throws(DeviceError) {
        let device = try requireDevice()
        var error = pb_error()
        let status = data.withUnsafeBytes { bytes in
            pb_send_partial(device, objectID, offset, bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count), &error)
        }
        try Self.check(status, error)
    }

    func endEdit(objectID: UInt32) throws(DeviceError) {
        let device = try requireDevice()
        var error = pb_error()
        try Self.check(pb_end_edit(device, objectID, &error), error)
    }

    func close() {
        guard let device else { return }
        self.device = nil
        pb_close(device)
    }

    private func requireDevice() throws(DeviceError) -> OpaquePointer {
        guard let device else { throw .disconnected }
        return device
    }

    /// C callback: reports progress and returns non-zero to make libmtp abort.
    private static let progressCallback: pb_progress_fn = { sent, total, context in
        guard let context else { return 0 }
        let progress = Unmanaged<TransferProgress>.fromOpaque(context).takeUnretainedValue()
        progress.update(completed: sent, total: total)
        return progress.isCancelled ? 1 : 0
    }

    private static func objectInfo(_ object: pb_object) -> MTPObjectInfo {
        MTPObjectInfo(
            objectID: object.object_id,
            parentID: object.parent_id,
            storageID: object.storage_id,
            name: objectName(object.name) ?? String(format: "object-%08X", object.object_id),
            size: object.size,
            modified: object.modified > 0 ? Date(timeIntervalSince1970: TimeInterval(object.modified)) : nil,
            isFolder: object.is_folder
        )
    }

    private static func check(_ status: pb_status, _ error: pb_error) throws(DeviceError) {
        guard status != PB_STATUS_OK else { return }
        var error = error
        let message = String(cString: pb_error_message(&error))
        Log.mtp.error("libmtp call failed: \(message, privacy: .public)")
        throw MTPErrorMapper.map(rawStatus: Int32(status.rawValue), nativeCode: error.native_code, message: message)
            ?? .unknown(detail: message)
    }

    /// Object names are kept byte-for-byte: trimming would make "a.txt" and
    /// "a.txt " the same name, so conflict checks could pick the wrong object.
    private static func objectName(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    private static func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
