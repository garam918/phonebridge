import CryptoKit
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

    /// An iPhone/iPad served by `AppleDeviceManager` (D75).
    var isAppleMobile: Bool { rawValue.hasPrefix("ios:") }

    /// The form of this id in a Finder volume address. The raw id holds the
    /// USB serial number, and the mount source URL is visible to every user
    /// of the Mac (`mount`, `statfs`), so real devices get a keyed hash that
    /// is stable for this launch only: `usb:04e8:h<16 hex>` (audit 2026-10-28).
    /// The demo device keeps its name. Resolve with `DeviceBroker`'s records.
    var volumeKey: String {
        if self == .demo { return rawValue }
        let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        let prefix = parts.count == 3 ? "\(parts[0]):\(parts[1]):" : "dev:"
        var hasher = SHA256()
        hasher.update(data: Self.volumeSalt)
        hasher.update(data: Data(rawValue.utf8))
        let digest = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        return prefix + "h" + digest
    }

    /// Random per launch: a key cannot be matched against a known serial.
    private static let volumeSalt: Data = {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes)
    }()
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
