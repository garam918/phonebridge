import Foundation

/// Name validation and collision handling shared by Android and Mac sides.
enum FileNameRules {
    /// Prefix of staging objects/files. Unique per transfer, so cleanup can
    /// never touch a user's file.
    static let temporaryPrefix = ".phonebridge-"

    /// Characters Android's FAT/exFAT SD cards and the MTP layer reject.
    static let forbiddenCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")

    /// The form a name is stored in on the device: precomposed Unicode (NFC).
    /// macOS file names are often decomposed (NFD: '한' as ㅎ+ㅏ+ㄴ, from zip
    /// archives, older disks, some apps); Android shows such names as separate
    /// jamo. Swift compares both forms as equal, but the device stores bytes.
    static func deviceForm(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// nil when `name` can be used for a new file or folder on the device.
    static func validationError(for rawName: String) -> DeviceError? {
        let name = deviceForm(rawName)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return .invalidName }
        guard trimmed == name else { return .invalidName }
        guard name.rangeOfCharacter(from: forbiddenCharacters) == nil else { return .invalidName }
        // MTP strings are UTF-16 with at most 255 units including the terminator;
        // Android file systems allow 255 UTF-8 bytes.
        guard name.utf16.count <= 254, name.utf8.count <= 255 else { return .invalidName }
        guard !name.hasPrefix(temporaryPrefix) else { return .invalidName }
        return nil
    }

    /// Makes a Mac file name acceptable on the device (uploads).
    static func sanitizedForDevice(_ name: String) -> String {
        var result = String(deviceForm(name).unicodeScalars.map { forbiddenCharacters.contains($0) ? "_" : Character($0) })
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty || result == "." || result == ".." { result = "_" }
        while result.utf16.count > 254 || result.utf8.count > 255 {
            result.removeLast()
        }
        return result
    }

    /// Finder-style "name 2.ext", "name 3.ext", ... not in `existing`
    /// (compared case-insensitively, like Android shared storage).
    static func uniqueName(for name: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }

    /// A name reported by a device, made safe as a single path component on
    /// the Mac and in the Finder volume: "/" and NUL become "_", and "", "."
    /// and ".." become "_". Android never creates such names, but any MTP
    /// responder can report them (audit 2026-10-23, H4). Other names pass
    /// through unchanged.
    static func singleComponent(_ name: String) -> String {
        var result = name
        if result.contains("/") || result.contains("\u{0}") {
            result = result.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\u{0}", with: "_")
        }
        if result.isEmpty || result == "." || result == ".." { result = "_" }
        return result
    }

    static func temporaryName(suffix: String = "part") -> String {
        "\(temporaryPrefix)\(UUID().uuidString.prefix(13).lowercased()).\(suffix)"
    }

    static func isTemporary(_ name: String) -> Bool {
        name.hasPrefix(temporaryPrefix)
    }
}

/// Free-space source for the local disk (injectable for tests).
protocol LocalVolumeInspecting: Sendable {
    func availableCapacity(for url: URL) -> UInt64?
}

struct SystemLocalVolume: LocalVolumeInspecting {
    func availableCapacity(for url: URL) -> UInt64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return UInt64(important) }
        return values.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
    }
}

/// Real home folders. Inside the sandbox `FileManager` reports the container,
/// but the Downloads entitlement grants the user's real ~/Downloads.
enum UserFolders {
    static var home: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(filePath: String(cString: dir), directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var downloads: URL { home.appending(path: "Downloads", directoryHint: .isDirectory) }
}
