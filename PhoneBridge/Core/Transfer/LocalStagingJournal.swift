import Foundation

/// Remembers the hidden download staging files PhoneBridge writes on the Mac
/// (`.phonebridge-….download`, next to the destination). A crash or a forced
/// quit in the middle of a download leaves one behind in the user's folder;
/// the next launch removes it.
///
/// The folder is kept as an app-scoped security bookmark so the sandboxed app
/// can reach it again after a relaunch. Only files with the exact recorded
/// temporary name are ever removed.
@MainActor
final class LocalStagingJournal {
    struct Entry: Codable, Hashable, Sendable {
        var id = UUID()
        var folderBookmark: Data
        /// Fallback when the bookmark cannot be resolved (app's own container).
        var folderPath: String
        var name: String
        var run: UUID
    }

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
        DeviceLeftoverJournal.defaultFileURL?.deletingLastPathComponent().appending(path: "LocalStaging.json")
    }

    /// Records `staging` before it is created. Returns nil when the name is not
    /// a PhoneBridge temporary name (never recorded, never removed).
    @discardableResult
    func record(_ staging: URL) -> UUID? {
        let name = staging.lastPathComponent
        guard FileNameRules.isTemporary(name) else { return nil }
        let folder = staging.deletingLastPathComponent()
        let bookmark = (try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)) ?? Data()
        let entry = Entry(folderBookmark: bookmark, folderPath: folder.path(percentEncoded: false), name: name, run: run)
        entries.append(entry)
        save()
        return entry.id
    }

    func remove(_ id: UUID?) {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        save()
    }

    /// Removes staging files left by earlier launches. Returns how many files
    /// were deleted; entries whose folder cannot be reached are dropped.
    @discardableResult
    func sweep() -> Int {
        var removed = 0
        var kept: [Entry] = []
        for entry in entries {
            guard entry.run != run else {
                kept.append(entry)
                continue
            }
            var stale = false
            let resolved = entry.folderBookmark.isEmpty ? nil
                : try? URL(resolvingBookmarkData: entry.folderBookmark, options: .withSecurityScope, relativeTo: nil,
                           bookmarkDataIsStale: &stale)
            let folder = resolved ?? URL(fileURLWithPath: entry.folderPath, isDirectory: true)
            let scoped = resolved?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let file = folder.appending(path: entry.name, directoryHint: .notDirectory)
            if FileNameRules.isTemporary(file.lastPathComponent), (try? FileManager.default.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        entries = kept
        save()
        if removed > 0 {
            Log.transfer.info("removed \(removed) download staging file(s) left by an earlier launch")
        }
        return removed
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Log.transfer.error("local staging journal not saved: \(error.publicSummary, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }
}
