import Foundation

/// Where an MTP device sits on the bus, in libusb terms.
struct MTPTarget: Hashable, Sendable {
    var bus: UInt32
    var address: UInt8
    var vendorID: UInt16
    var productID: UInt16

    init(bus: UInt32, address: UInt8, vendorID: UInt16, productID: UInt16) {
        self.bus = bus
        self.address = address
        self.vendorID = vendorID
        self.productID = productID
    }

    init(snapshot: USBDeviceSnapshot) {
        self.init(bus: snapshot.busNumber, address: snapshot.address,
                  vendorID: snapshot.vendorID, productID: snapshot.productID)
    }
}

struct MTPObjectInfo: Equatable, Sendable {
    var objectID: UInt32
    var parentID: UInt32
    var storageID: UInt32
    var name: String
    var size: UInt64
    var modified: Date?
    var isFolder: Bool
}

/// Result of the libusb claim test that runs before libmtp opens a session.
enum MTPPreflightResult: Equatable, Sendable {
    case available
    /// Another process holds the interface.
    case busy
    case noMTPInterface
    case failed(DeviceError)
}

/// Blocking MTP primitives. Implementations are not thread-safe per
/// connection: `MTPDeviceSession` is the only caller and serializes them on a
/// per-device queue, off the main thread.
protocol MTPBackend: Sendable {
    func preflight(_ target: MTPTarget) -> MTPPreflightResult
    func open(_ target: MTPTarget) throws(DeviceError) -> any MTPConnection
}

/// Optional MTP operations advertised by the device (PBMTPBridge PB_CAP_*).
struct MTPCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: UInt32

    static let moveObject = MTPCapabilities(rawValue: 1 << 0)
    static let copyObject = MTPCapabilities(rawValue: 1 << 1)
    static let rename = MTPCapabilities(rawValue: 1 << 2)
    static let partialGet = MTPCapabilities(rawValue: 1 << 3)
    static let partialSend = MTPCapabilities(rawValue: 1 << 4)
    static let editObjects = MTPCapabilities(rawValue: 1 << 5)

    var fileSystemCapabilities: FileSystemCapabilities {
        // Upload / create / delete are mandatory parts of MTP that Android
        // implements; storage-level read-only flags are applied separately.
        FileSystemCapabilities(canWrite: true, canRename: contains(.rename),
                               canMoveNatively: contains(.moveObject), canCopyNatively: contains(.copyObject),
                               canThumbnail: true, canReadPartially: contains(.partialGet),
                               canUploadInChunks: contains(.editObjects) && contains(.partialSend))
    }
}

protocol MTPConnection: AnyObject {
    func deviceInfo() -> MTPDeviceInfo
    func capabilities() -> MTPCapabilities
    func storages() throws(DeviceError) -> [StorageInfo]
    func listFolder(storageID: UInt32, parentID: UInt32) throws(DeviceError) -> [MTPObjectInfo]
    /// Number of object handles in the folder (GetObjectHandles only).
    func childCount(storageID: UInt32, parentID: UInt32) throws(DeviceError) -> Int
    func objectInfo(objectID: UInt32) throws(DeviceError) -> MTPObjectInfo
    /// Streams the object into `fd`. Polls `progress.isCancelled`.
    func download(objectID: UInt32, to fd: Int32, progress: TransferProgress) throws(DeviceError)
    /// Streams `size` bytes from `fd` into a new object; returns its handle.
    func upload(from fd: Int32, name: String, size: UInt64, modified: Date?, storageID: UInt32, parentID: UInt32,
                progress: TransferProgress) throws(DeviceError) -> UInt32
    func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws(DeviceError) -> UInt32
    func rename(objectID: UInt32, to name: String) throws(DeviceError)
    func delete(objectID: UInt32) throws(DeviceError)
    func move(objectID: UInt32, storageID: UInt32, parentID: UInt32) throws(DeviceError)
    func copy(objectID: UInt32, storageID: UInt32, parentID: UInt32) throws(DeviceError)
    func thumbnail(objectID: UInt32) throws(DeviceError) -> Data
    /// Range read (GetPartialObject). Only when `.partialGet` is advertised.
    func readPartial(objectID: UInt32, offset: UInt64, length: UInt32) throws(DeviceError) -> Data
    /// Android edit extension (`.editObjects` + `.partialSend`).
    func beginEdit(objectID: UInt32) throws(DeviceError)
    func sendPartial(objectID: UInt32, offset: UInt64, data: Data) throws(DeviceError)
    func endEdit(objectID: UInt32) throws(DeviceError)
    func close()
}
