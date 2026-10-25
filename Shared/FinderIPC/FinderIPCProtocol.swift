import Foundation

/// Wire protocol between the PhoneBridge app (which owns DeviceBroker and the
/// MTP sessions) and the FSKit extension (which only translates Finder
/// requests). Compiled into both targets.
enum FinderIPC {
    /// 2: write requests (2단계, FINDER_WRITE_PLAN.md §6).
    /// 3: responses too large for a header travel in the body (`encodedInBody`).
    static let protocolVersion = 3
    static let urlScheme = "phonebridge"
    static let extensionSuffix = ".FinderVolume"
    /// Derived from the running bundle so a team-specific bundle-ID prefix
    /// needs no code change (embedded bundles are `<app id>.FinderVolume`
    /// and `<app id>.Unmounter`).
    static var appBundleIdentifier: String {
        let own = Bundle.main.bundleIdentifier ?? "com.phonebridge.PhoneBridge"
        for suffix in [extensionSuffix, VolumeUnmountPolicy.serviceSuffix] where own.hasSuffix(suffix) {
            return String(own.dropLast(suffix.count))
        }
        return own
    }
    static var extensionBundleIdentifier: String { appBundleIdentifier + extensionSuffix }
    static let socketFileName = "finder-broker.sock"
    /// Folder in the App Group container where the extension keeps the local
    /// buffers of files being written; commits name a file in it.
    static let writeBufferFolderName = "FinderWrites"
    /// Prefix of PhoneBridge's hidden objects on devices (`FileNameRules.temporaryPrefix`).
    static let temporaryPrefix = ".phonebridge-"
    /// Info.plist key holding the App Group identifier ($(PB_APP_GROUP)).
    static let appGroupInfoKey = "PBAppGroupIdentifier"
    static let maxHeaderSize = 4 << 20
    static let maxBodySize = 64 << 20

    /// FSKit short name (`mount -F -t <name>`); development builds use their own.
    static var fileSystemShortName: String {
        Bundle.main.object(forInfoDictionaryKey: "PBFileSystemShortName") as? String ?? "phonebridge"
    }

    static var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String
    }

    /// Socket inside the shared App Group container, or nil when the process
    /// has no usable App Group (e.g. ad-hoc signing without a team).
    static func defaultSocketURL() -> URL? {
        guard let group = appGroupIdentifier, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appending(path: socketFileName)
    }

    static func defaultWriteBufferDirectory() -> URL? {
        guard let group = appGroupIdentifier, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appending(path: writeBufferFolderName, directoryHint: .isDirectory)
    }

    /// A buffer is named by one plain path component inside the buffer folder.
    static func isValidBufferName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.hasPrefix(".") && name.utf8.count <= 128
    }
}

/// Identifies one mountable volume: a storage of a device in one session.
struct VolumeAddress: Codable, Hashable, Sendable {
    var deviceID: String
    var storageID: UInt32
    var generation: UInt64

    /// `phonebridge://volume?device=<id>&storage=<hex>&generation=<n>`
    var url: URL {
        var components = URLComponents()
        components.scheme = FinderIPC.urlScheme
        components.host = "volume"
        components.queryItems = [
            URLQueryItem(name: "device", value: deviceID),
            URLQueryItem(name: "storage", value: String(storageID, radix: 16)),
            URLQueryItem(name: "generation", value: String(generation)),
        ]
        return components.url!
    }

    init(deviceID: String, storageID: UInt32, generation: UInt64) {
        self.deviceID = deviceID
        self.storageID = storageID
        self.generation = generation
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == FinderIPC.urlScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let device = value("device"), !device.isEmpty,
              let storageText = value("storage"), let storage = UInt32(storageText, radix: 16),
              let generationText = value("generation"), let generation = UInt64(generationText) else { return nil }
        self.init(deviceID: device, storageID: storage, generation: generation)
    }

    /// Diagnostics: `&staging=1` on a mount URL lists hidden staging/backup
    /// objects in that mount only (leftover checks on a separate mount). The
    /// app never mounts with it: an object being uploaded must not become a
    /// Finder item (V12).
    static func showsStagingObjects(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "staging" && $0.value == "1" } == true
    }

    /// Stable per volume and session; used as FSKit container identifier.
    var uuid: UUID {
        // Derived from the text (Hasher is randomly seeded per process).
        let text = Array("\(deviceID)|\(storageID)|\(generation)".utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in text.enumerated() {
            bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Root of a storage in MTP terms.
let remoteRootObjectID: UInt32 = 0xFFFF_FFFF

struct RemoteEntry: Codable, Hashable, Sendable {
    var objectID: UInt32
    var parentID: UInt32
    var name: String
    var isFolder: Bool
    var size: UInt64
    /// Seconds since 1970, nil when the device did not report it.
    var modified: Double?
}

struct VolumeDescription: Codable, Hashable, Sendable {
    var name: String
    /// ASCII name FSKit uses for the `/Volumes/…` mount point; fskitd rejects
    /// non-ASCII mount-point names with EINVAL (verified on macOS 27).
    var mountName: String?
    var capacity: UInt64?
    var freeSpace: UInt64?
    var isReadOnly: Bool
    var canReadPartially: Bool
    var isDemo: Bool

    /// `preferred` when it is already a usable ASCII name, otherwise
    /// `fallback` reduced to ASCII.
    static func mountSafeName(_ preferred: String, fallback: String) -> String {
        func allowed(_ scalar: Unicode.Scalar) -> Bool { (0x20..<0x7F).contains(scalar.value) && scalar != "/" && scalar != ":" }
        if !preferred.isEmpty, preferred.unicodeScalars.allSatisfy(allowed) { return preferred }
        let ascii = String(String.UnicodeScalarView(fallback.unicodeScalars.filter(allowed)))
        let words = ascii.split(separator: " ").joined(separator: " ")
        return words.isEmpty ? "PhoneBridge" : words
    }
}

/// What the volume may do right now (asked once per mount and after errors).
struct WriteCapabilities: Codable, Hashable, Sendable {
    /// Settings allow Finder writes and the storage is writable.
    var allowsWrites: Bool
    var canRename: Bool
    /// Native MTP MoveObject; without it a move across folders is EXDEV.
    var canMove: Bool
}

/// Upload of a file the extension has finished writing locally.
struct CommitRequest: Codable, Hashable, Sendable {
    var parent: UInt32
    /// Folder names from the storage root, so leftovers of an interrupted
    /// commit can be found in a later session (handles may change).
    var parentPath: [String]? = nil
    var name: String
    /// The device object this file replaces (from the extension's view);
    /// a different existing object under `name` is a conflict (EEXIST).
    var replacing: UInt32?
    /// File name inside the write buffer folder (`FinderIPC.writeBufferFolderName`).
    var bufferName: String
    var size: UInt64
    var modified: Double?
}

enum FinderRequest: Codable, Sendable, Equatable {
    case hello(version: Int)
    case describe(VolumeAddress)
    case list(VolumeAddress, parent: UInt32)
    case stat(VolumeAddress, object: UInt32)
    /// Response body carries the bytes.
    case read(VolumeAddress, object: UInt32, offset: UInt64, length: Int)
    case writeCapabilities(VolumeAddress)
    /// Every write names its folders from the storage root (`…Path`), so the
    /// app can clean up later (W3) and keep test writes in one folder (W5).
    case createFolder(VolumeAddress, parent: UInt32, parentPath: [String]?, name: String)
    case commitFile(VolumeAddress, CommitRequest)
    /// Same-folder rename; `replacing` as in `CommitRequest`.
    case rename(VolumeAddress, object: UInt32, parent: UInt32, parentPath: [String]?, name: String, replacing: UInt32?)
    /// Cross-folder rename (move from `from` into `parent`, optionally renamed).
    case move(VolumeAddress, object: UInt32, from: UInt32, fromPath: [String]?, parent: UInt32, parentPath: [String]?, name: String,
              replacing: UInt32?)
    /// Files are deleted after a grace period (D33); folders must be empty.
    case delete(VolumeAddress, object: UInt32, parent: UInt32, parentPath: [String]?)

    /// Safe to send again after a lost reply.
    var isIdempotent: Bool {
        switch self {
        case .hello, .describe, .list, .stat, .read, .writeCapabilities: true
        case .createFolder, .commitFile, .rename, .move, .delete: false
        }
    }
}

enum FinderResponse: Codable, Sendable, Equatable {
    case hello(version: Int)
    case volume(VolumeDescription)
    case entries([RemoteEntry])
    case entry(RemoteEntry)
    case data(count: Int)
    case writeCapabilities(WriteCapabilities)
    case done
    case failure(FinderIPCError)
    /// The real response is JSON in the frame body: it was larger than
    /// `maxHeaderSize` (a folder with tens of thousands of items).
    case encodedInBody
}

/// Error crossing the IPC boundary; `code` is a POSIX errno for FSKit.
struct FinderIPCError: Error, Codable, Sendable, Equatable {
    var code: Int32
    var message: String

    static func transport(_ message: String) -> FinderIPCError { FinderIPCError(code: EIO, message: message) }
}
