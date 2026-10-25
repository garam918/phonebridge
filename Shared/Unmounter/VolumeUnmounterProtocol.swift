import Foundation

/// XPC interface of `PhoneBridgeUnmounter.xpc`, the one non-sandboxed piece
/// of PhoneBridge. Volumes mounted with `FSClient` belong to root, and App
/// Sandbox refuses the authorization right needed to unmount them (V7-8), so
/// the sandboxed app asks this helper instead.
@objc protocol VolumeUnmounting {
    /// Replies with 0 or an errno, plus a message for the log.
    func unmountVolume(atPath path: String, reply: @escaping @Sendable (Int32, String?) -> Void)
}

enum VolumeUnmountPolicy {
    static let serviceSuffix = ".Unmounter"
    static var serviceName: String { FinderIPC.appBundleIdentifier + serviceSuffix }

    /// The helper unmounts nothing but this build's PhoneBridge volumes under
    /// /Volumes (a development build never touches release volumes).
    static func allows(fileSystemType: String, mountedFrom: String, mountedOn: String, requested: String) -> Bool {
        fileSystemType == FinderIPC.fileSystemShortName
            && mountedFrom.hasPrefix(FinderIPC.urlScheme + "://")
            && mountedOn.hasPrefix("/Volumes/")
            && mountedOn == requested
    }

    /// Checks the live mount table entry for `path`; returns 0 or an errno.
    static func check(path: String) -> Int32 {
        guard let resolved = realpath(path, nil) else { return errno }
        defer { free(resolved) }
        var info = statfs()
        guard statfs(resolved, &info) == 0 else { return errno }
        let entry = MountEntry(info)
        return allows(fileSystemType: entry.type, mountedFrom: entry.from, mountedOn: entry.on,
                      requested: String(cString: resolved)) ? 0 : EPERM
    }

    /// PhoneBridge volumes currently mounted under /Volumes.
    static func currentMounts() -> [String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return (0..<Int(count)).compactMap { index in
            let entry = MountEntry(buffer[index])
            return allows(fileSystemType: entry.type, mountedFrom: entry.from, mountedOn: entry.on, requested: entry.on) ? entry.on : nil
        }
    }

    private struct MountEntry {
        let type: String
        let from: String
        let on: String

        init(_ info: statfs) {
            func text<T>(_ field: T) -> String {
                withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            type = text(info.f_fstypename)
            from = text(info.f_mntfromname)
            on = text(info.f_mntonname)
        }
    }
}
