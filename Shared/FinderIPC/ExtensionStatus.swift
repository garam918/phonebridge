import Foundation

/// A small status file the Finder extension keeps in the App Group container
/// so Help › Export Diagnostics can include the extension's side: the app
/// cannot read the extension's log (separate sandboxed process). Holds event
/// kinds, error codes and error keys only — never file, folder or device names.
struct ExtensionStatus: Codable, Sendable, Equatable {
    struct Event: Codable, Sendable, Equatable {
        var date: Date
        var kind: String
        var detail: String
        var processID: Int32
    }

    var updated: Date
    var version: String
    /// Volumes mounted per extension process (FSKit may run one per volume).
    var mountedByProcess: [String: Int]
    var events: [Event]

    var mountedVolumes: Int { mountedByProcess.values.reduce(0, +) }

    static let fileName = "ExtensionStatus.json"
    static let eventLimit = 100

    static func defaultURL() -> URL? {
        guard let group = FinderIPC.appGroupIdentifier, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appending(path: fileName)
    }

    static func read(from url: URL?) -> ExtensionStatus? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExtensionStatus.self, from: data)
    }
}

/// Extension side: appends events to the status file. Every write re-reads
/// the file under an advisory lock, so several extension processes share it.
final class ExtensionStatusRecorder: @unchecked Sendable {
    static let shared = ExtensionStatusRecorder(url: ExtensionStatus.defaultURL())

    private let lock = NSLock()
    private let url: URL?
    private let version: String
    private let processID: Int32
    /// Whether another process is still running (signal 0; EPERM means it exists).
    private let isAlive: @Sendable (Int32) -> Bool

    init(url: URL?, processID: Int32 = ProcessInfo.processInfo.processIdentifier,
         isAlive: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.url = url
        self.processID = processID
        self.isAlive = isAlive
        version = [Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"),
                   Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")]
            .compactMap { $0 as? String }.joined(separator: " ")
    }

    var current: ExtensionStatus? { ExtensionStatus.read(from: url) }

    /// Socket errors name a path in the user's home folder (the account name).
    static func withoutUserPaths(_ text: String) -> String {
        text.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "/Users/…", options: .regularExpression)
    }

    func record(_ kind: String, _ detail: String = "", mountedChange: Int = 0, now: Date = Date()) {
        guard let url else { return }
        lock.lock()
        defer { lock.unlock() }
        let lockFD = open(url.path(percentEncoded: false) + ".lock", O_RDWR | O_CREAT, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer {
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
        }

        var status = ExtensionStatus.read(from: url)
            ?? ExtensionStatus(updated: now, version: version, mountedByProcess: [:], events: [])
        let me = String(processID)
        // Processes that ended (or crashed) have nothing mounted any more.
        for key in status.mountedByProcess.keys where key != me && !(Int32(key).map(isAlive) ?? false) {
            status.mountedByProcess[key] = nil
        }
        status.updated = now
        status.version = version
        status.mountedByProcess[me] = max(0, (status.mountedByProcess[me] ?? 0) + mountedChange)
        if status.mountedByProcess[me] == 0 { status.mountedByProcess[me] = nil }
        status.events.append(.init(date: now, kind: kind, detail: Self.withoutUserPaths(detail), processID: processID))
        if status.events.count > ExtensionStatus.eventLimit {
            status.events.removeFirst(status.events.count - ExtensionStatus.eventLimit)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(status).write(to: url, options: .atomic)
    }
}
