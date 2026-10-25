import Foundation

/// Stable identity of a physical device across re-enumerations.
///
/// Android keeps the same USB serial number when the user switches between
/// "charging only" and "file transfer", while the product id and the IOKit
/// registry id change. Keying by vendor + serial lets the broker treat the
/// re-enumerated device as the same logical device.
struct DeviceID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    static let demo = DeviceID("demo:virtual-android")
}

/// Identifies a file or folder on a device: MTP object handles are only unique
/// per storage, and only valid for the session that produced them.
struct FileItemID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// MTP uses 0xFFFFFFFF as "parent of the storage root".
    static let rootObjectID: UInt32 = 0xFFFF_FFFF

    let deviceID: DeviceID
    let storageID: UInt32
    let objectID: UInt32

    static func root(deviceID: DeviceID, storageID: UInt32) -> FileItemID {
        FileItemID(deviceID: deviceID, storageID: storageID, objectID: rootObjectID)
    }

    var isStorageRoot: Bool { objectID == Self.rootObjectID }

    var description: String {
        "\(deviceID)/\(String(storageID, radix: 16))/\(String(objectID, radix: 16))"
    }
}

enum StorageKind: String, Sendable, Hashable {
    case internalStorage
    case removable
    case unknown
}

struct StorageInfo: Identifiable, Hashable, Sendable {
    let id: UInt32
    var name: String
    var volumeIdentifier: String?
    var capacity: UInt64?
    var freeSpace: UInt64?
    var kind: StorageKind
    var isReadOnly: Bool

    var usedSpace: UInt64? {
        guard let capacity, let freeSpace, capacity >= freeSpace else { return nil }
        return capacity - freeSpace
    }

    /// Maps PTP StorageType / AccessCapability codes (PTP spec 5.5.3).
    init(mtpStorageID: UInt32, description: String?, volumeIdentifier: String?,
         storageType: UInt16, accessCapability: UInt16, capacity: UInt64, freeSpace: UInt64) {
        id = mtpStorageID
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        name = trimmed.isEmpty ? String(format: "Storage %08X", mtpStorageID) : trimmed
        self.volumeIdentifier = volumeIdentifier
        // libmtp reports UInt64.max when the device does not provide sizes.
        self.capacity = capacity == UInt64.max ? nil : capacity
        self.freeSpace = freeSpace == UInt64.max ? nil : freeSpace
        switch storageType {
        case 0x0001, 0x0003: kind = .internalStorage   // FixedROM, FixedRAM
        case 0x0002, 0x0004: kind = .removable         // RemovableROM, RemovableRAM
        default: kind = .unknown
        }
        isReadOnly = accessCapability != 0x0000
    }

    init(id: UInt32, name: String, volumeIdentifier: String? = nil, capacity: UInt64?, freeSpace: UInt64?,
         kind: StorageKind, isReadOnly: Bool = false) {
        self.id = id
        self.name = name
        self.volumeIdentifier = volumeIdentifier
        self.capacity = capacity
        self.freeSpace = freeSpace
        self.kind = kind
        self.isReadOnly = isReadOnly
    }
}

struct MTPDeviceInfo: Equatable, Sendable {
    var manufacturer: String?
    var model: String?
    var serialNumber: String?
    var deviceVersion: String?
    var friendlyName: String?
    var batteryLevel: Int?
}
