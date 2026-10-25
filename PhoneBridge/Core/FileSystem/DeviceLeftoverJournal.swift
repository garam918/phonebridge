import Foundation

/// Remembers the hidden objects PhoneBridge creates on a device in the middle
/// of an operation — staging uploads, backups of replaced files, delayed
/// deletes (D16, D26, D33) — so that a crash, an unplug or a quit in the
/// middle can be cleaned up in the device's next session (W3).
///
/// Entries are written before the object exists and removed once it is gone,
/// so an entry may name an object that never got created; the sweep simply
/// drops those. Only objects with the exact recorded temporary name are ever
/// touched, so a stale entry can never hit a user's file.
@MainActor
final class DeviceLeftoverJournal {
    struct Entry: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// Upload under a hidden name, not yet verified: always removed.
            case staging
            /// A user's file moved aside under a hidden name (replace backup or
            /// delayed delete): restored when its name is still free, else removed.
            case backup
        }

        var id = UUID()
        var device: String
        var storageID: UInt32
        var folder: UInt32
        /// Folder names from the storage root; object handles may change
        /// between sessions, names do not.
        var folderPath: [String]?
        var name: String
        var originalName: String?
        var kind: Kind
        var run: UUID
        var generation: UInt64
    }

    struct SweepReport: Equatable, Sendable {
        var removed = 0
        var restored = 0
        var kept = 0
    }

    /// Identifies this app launch; entries of the running launch's current
    /// session are never swept.
    static let currentRun = UUID()

    private(set) var entries: [Entry] = []
    private let fileURL: URL?
    private let run: UUID

    /// `fileURL` nil keeps the journal in memory (tests).
    init(fileURL: URL?, run: UUID = DeviceLeftoverJournal.currentRun) {
        self.fileURL = fileURL
        self.run = run
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    static var defaultFileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appending(path: "PhoneBridge", directoryHint: .isDirectory).appending(path: "DeviceLeftovers.json")
    }

    @discardableResult
    func record(_ kind: Entry.Kind, named name: String, in folder: FileItemID, path: [String]?, originalName: String? = nil,
                generation: UInt64) -> UUID {
        let entry = Entry(device: folder.deviceID.rawValue, storageID: folder.storageID, folder: folder.objectID, folderPath: path,
                          name: name, originalName: originalName, kind: kind, run: run, generation: generation)
        entries.append(entry)
        save()
        return entry.id
    }

    func remove(_ id: UUID?) {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        save()
    }

    /// Cleans up what earlier sessions of `fs`'s device left behind.
    func sweep(_ fs: any DeviceFileSystem) async -> SweepReport {
        var report = SweepReport()
        let device = fs.deviceID.rawValue
        let candidates = entries.filter { $0.device == device && ($0.run != run || $0.generation != fs.generation) }
        for entry in candidates {
            do throws(DeviceError) {
                if try await clean(entry, fs: fs, report: &report) {
                    remove(entry.id)
                } else {
                    report.kept += 1
                }
            } catch {
                report.kept += 1
                // The device went away again: try next time.
                if error == .disconnected { break }
            }
        }
        if report.removed + report.restored > 0 {
            Log.transfer.info("cleaned \(report.removed) leftover object(s), restored \(report.restored)")
        }
        return report
    }

    /// true when the entry is settled (cleaned, or nothing left to clean).
    private func clean(_ entry: Entry, fs: any DeviceFileSystem, report: inout SweepReport) async throws(DeviceError) -> Bool {
        guard FileNameRules.isTemporary(entry.name) else { return true }
        guard let siblings = try await locate(entry, fs: fs),
              let leftover = siblings.first(where: { $0.name == entry.name && !$0.isFolder }) else { return true }
        if entry.kind == .backup, let original = entry.originalName {
            let taken = siblings.contains { !FileNameRules.isTemporary($0.name) && $0.name.lowercased() == original.lowercased() }
            if !taken, fs.capabilities.canRename {
                _ = try await fs.rename(leftover.id, to: original)
                report.restored += 1
                Log.transfer.info("restored \(original, privacy: .private) left aside by an interrupted operation")
                return true
            }
        }
        try await fs.delete(leftover.id)
        report.removed += 1
        return true
    }

    /// The entry's folder and its contents: by handle first (Android keeps
    /// them), then by path. nil when neither finds the leftover.
    private func locate(_ entry: Entry, fs: any DeviceFileSystem) async throws(DeviceError) -> [FileItem]? {
        let byHandle = FileItemID(deviceID: fs.deviceID, storageID: entry.storageID, objectID: entry.folder)
        do throws(DeviceError) {
            let items = try await fs.contents(of: byHandle)
            if items.contains(where: { $0.name == entry.name }) { return items }
        } catch where error != .disconnected {
        }
        guard let path = entry.folderPath else { return nil }
        var folder = FileItemID(deviceID: fs.deviceID, storageID: entry.storageID, objectID: FileItemID.rootObjectID)
        for name in path {
            guard let next = try await fs.contents(of: folder).first(where: { $0.isFolder && $0.name == name }) else { return nil }
            folder = next.id
        }
        let items = try await fs.contents(of: folder)
        return items.contains(where: { $0.name == entry.name }) ? items : nil
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Log.transfer.error("could not save the leftover journal: \(error.publicSummary, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }
}
