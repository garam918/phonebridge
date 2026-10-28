import Foundation

/// Applies Finder writes to a device (2단계, FINDER_WRITE_PLAN.md). Uses the
/// same safety rules as app uploads (`SafeDeviceWrite`: hidden staging name,
/// size check, backup swap, restore on failure, D16, D26) plus delayed
/// deletes (D33): Finder's
/// "Replace" deletes the original before writing the new file, so a deleted
/// file is only hidden under a backup name until the replacement is safely
/// on the device or the grace period ends.
///
/// A pending delete outlives its grace period while a replacement is still
/// on its way: a commit, rename or move of that name queued or running, or a
/// write buffer for it that the extension still holds (audit 2026-10-23, H3).
///
/// Requests run one at a time, in arrival order.
@MainActor
final class FinderWriteCoordinator {
    private struct PendingDelete {
        let backup: FileItemID
        let parent: FileItemID
        let path: [String]?
        let originalName: String
        let fileSystem: any DeviceFileSystem
        var timer: Task<Void, Never>
        let journalEntry: UUID
    }

    private let bufferDirectory: URL?
    private let deleteGrace: Duration
    /// Hidden objects in flight, cleaned in a later session after a crash (W3).
    let journal: DeviceLeftoverJournal
    private var pendingDeletes: [String: PendingDelete] = [:]
    /// Commits, renames and moves queued or running, by target key.
    private var activeWrites: [String: Int] = [:]
    private var tail: Task<Void, Never>?

    init(bufferDirectory: URL?, deleteGrace: Duration = .seconds(30), journal: DeviceLeftoverJournal = DeviceLeftoverJournal(fileURL: nil)) {
        self.bufferDirectory = bufferDirectory
        self.deleteGrace = deleteGrace
        self.journal = journal
    }

    /// Deletes waiting for their grace period (tests, diagnostics).
    var pendingDeleteCount: Int { pendingDeletes.count }

    // MARK: - Requests

    func createFolder(named name: String, in parent: FileItemID, fileSystem fs: any DeviceFileSystem) async throws(FinderIPCError) -> FileItem {
        try await serialized { () throws(DeviceError) in
            try Self.validate(name)
            if try await Self.existing(named: name, in: parent, fs: fs) != nil { throw .nameConflict(name: name) }
            return try await fs.createFolder(named: name, in: parent)
        }
    }

    func commit(_ request: CommitRequest, in parent: FileItemID, freeSpace: UInt64?,
                fileSystem fs: any DeviceFileSystem) async throws(FinderIPCError) -> FileItem {
        guard FinderIPC.isValidBufferName(request.bufferName), let bufferDirectory else {
            throw FinderIPCError(code: EINVAL, message: "invalid write buffer")
        }
        let buffer = bufferDirectory.appending(path: request.bufferName)
        guard LocalFileIO.fileSize(buffer) == request.size else {
            throw FinderIPCError(code: EIO, message: "write buffer size mismatch")
        }
        return try await tracking(Self.key(parent, request.name), await serialized { [self] () throws(DeviceError) in
            try Self.validate(request.name)
            if let freeSpace, freeSpace < request.size {
                throw .insufficientDeviceSpace(required: request.size, available: freeSpace)
            }
            let existing = try await Self.existing(named: request.name, in: parent, fs: fs)
            if let existing {
                if existing.isFolder || existing.id.objectID != request.replacing { throw .nameConflict(name: request.name) }
            }
            let key = Self.key(parent, request.name)
            do throws(DeviceError) {
                let modified = request.modified.map { Date(timeIntervalSince1970: $0) }
                let final = try await upload(buffer, size: request.size, named: request.name, into: parent, path: request.parentPath,
                                             replacing: existing, modified: modified, fs: fs)
                await finishPendingDelete(key)
                return final
            } catch {
                await restorePendingDelete(key)
                throw error
            }
        })
    }

    func rename(_ object: FileItemID, in parent: FileItemID, to name: String, replacing: UInt32?,
                fileSystem fs: any DeviceFileSystem) async throws(FinderIPCError) -> FileItem {
        try await tracking(Self.key(parent, name), await serialized { [self] () throws(DeviceError) in
            try Self.validate(name)
            guard fs.capabilities.canRename else { throw .unsupportedOperation }
            let item = try await fs.item(object)
            if item.name == name { return item }
            let key = Self.key(parent, name)
            do throws(DeviceError) {
                let existing = try await Self.conflict(named: name, in: parent, ignoring: object, replacing: replacing, fs: fs)
                let renamed = try await swap(existing, in: parent, path: nil, fs: fs) { () throws(DeviceError) in
                    try await fs.rename(object, to: name)
                }
                await finishPendingDelete(key)
                return renamed
            } catch {
                await restorePendingDelete(key)
                throw error
            }
        })
    }

    func move(_ object: FileItemID, from source: FileItemID, to parent: FileItemID, name: String, replacing: UInt32?,
              fileSystem fs: any DeviceFileSystem) async throws(FinderIPCError) -> FileItem {
        try await tracking(Self.key(parent, name), await serialized { [self] () throws(DeviceError) in
            try Self.validate(name)
            // Without MoveObject Finder falls back to copy + delete itself.
            guard fs.capabilities.canMoveNatively else { throw .crossFolderMoveUnsupported }
            let item = try await fs.item(object)
            let key = Self.key(parent, name)
            do throws(DeviceError) {
                let existing = try await Self.conflict(named: name, in: parent, ignoring: object, replacing: replacing, fs: fs)
                let moved = try await swap(existing, in: parent, path: nil, fs: fs) { () throws(DeviceError) in
                    var moved = try await fs.move(object, to: parent)
                    guard item.name != name else { return moved }
                    do throws(DeviceError) {
                        moved = try await fs.rename(moved.id, to: name)
                    } catch {
                        // Put it back where it was rather than leave it half-done.
                        _ = try? await fs.move(moved.id, to: source)
                        throw error
                    }
                    return moved
                }
                await finishPendingDelete(key)
                return moved
            } catch {
                await restorePendingDelete(key)
                throw error
            }
        })
    }

    /// Files: hidden under a backup name, deleted after `deleteGrace` (D33).
    /// Folders: deleted now and must be empty apart from such backups.
    /// Devices without rename cannot hide a file, so Finder may not delete
    /// files there: Finder's "Replace" would lose the original whenever the
    /// new file then fails to upload (audit 2026-10-23, M5).
    func delete(_ object: FileItemID, in parent: FileItemID, path: [String]? = nil,
                fileSystem fs: any DeviceFileSystem) async throws(FinderIPCError) {
        try await serialized { [self] () throws(DeviceError) in
            let item = try await fs.item(object)
            if item.isFolder {
                try await deleteFolder(item, fs: fs)
                return
            }
            guard fs.capabilities.canRename else { throw .unsupportedOperation }
            let key = Self.key(parent, item.name)
            // An older delete of the same name is final by now.
            await finishPendingDelete(key)
            let backupName = FileNameRules.temporaryName(suffix: "deleted")
            let entry = journal.record(.backup, named: backupName, in: parent, path: path, originalName: item.name, generation: fs.generation)
            let backup: FileItem
            do throws(DeviceError) {
                backup = try await fs.rename(object, to: backupName)
            } catch {
                journal.remove(entry)
                throw error
            }
            pendingDeletes[key] = PendingDelete(backup: backup.id, parent: parent, path: path, originalName: item.name,
                                                fileSystem: fs, timer: graceTimer(key, backup: backup.id), journalEntry: entry)
            Log.finder.info("delete deferred: \(item.name, privacy: .private)")
        }
    }

    /// Ends every grace period now (unmount, session end, app quit). A
    /// delete whose replacement is still running is left to that request; one
    /// whose replacement is still being written in Finder stays on the device
    /// under its journaled backup name, restored in the next session.
    func finishAllPendingDeletes(deviceID: DeviceID? = nil) async {
        for (key, pending) in pendingDeletes where deviceID == nil || pending.backup.deviceID == deviceID {
            if activeWrites[key, default: 0] > 0 { continue }
            if replacementBufferIsOpen(for: pending) {
                pending.timer.cancel()
                pendingDeletes[key] = nil
                Log.finder.info("kept deleted \(pending.originalName, privacy: .private) for the next session: its replacement is unfinished")
                continue
            }
            await finishPendingDelete(key)
        }
    }

    // MARK: - Steps

    /// Stages, verifies and swaps one file into place (shared rules: `SafeDeviceWrite`).
    private func upload(_ buffer: URL, size: UInt64, named name: String, into parent: FileItemID, path: [String]?,
                        replacing existing: FileItem?, modified: Date?, fs: any DeviceFileSystem) async throws(DeviceError) -> FileItem {
        try await SafeDeviceWrite(fileSystem: fs, journal: journal)
            .upload(buffer, size: size, named: name, into: parent, path: path, replacing: existing, modified: modified,
                    progress: TransferProgress())
    }

    private func swap(_ existing: FileItem?, in parent: FileItemID, path: [String]?, fs: any DeviceFileSystem,
                      _ place: () async throws(DeviceError) -> FileItem) async throws(DeviceError) -> FileItem {
        try await SafeDeviceWrite(fileSystem: fs, journal: journal).swap(existing, in: parent, path: path, place)
    }

    private func deleteFolder(_ folder: FileItem, fs: any DeviceFileSystem) async throws(DeviceError) {
        // Files Finder deleted inside are still there under backup names.
        for key in pendingDeletes.keys where key.hasPrefix(Self.keyPrefix(folder.id)) {
            await finishPendingDelete(key)
        }
        let inside = try await fs.contents(of: folder.id)
        if inside.contains(where: { !FileNameRules.isTemporary($0.name) }) { throw .folderNotEmpty }
        // A `.bak` is the original of a replace that has not finished (or is
        // journaled for recovery): never delete it with the folder.
        if inside.contains(where: { $0.name.hasSuffix(".bak") }) { throw .folderNotEmpty }
        for leftover in inside where !leftover.isFolder {
            try await fs.delete(leftover.id)
        }
        // `contents` leaves out objects libmtp cannot read, and Android deletes
        // a folder recursively: ask the device itself whether it is empty.
        if try await fs.childCount(of: folder.id) > 0 { throw .folderNotEmpty }
        try await fs.delete(folder.id)
    }

    private func graceTimer(_ key: String, backup: FileItemID) -> Task<Void, Never> {
        let grace = deleteGrace
        return Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.expire(key, backup: backup)
        }
    }

    private func expire(_ key: String, backup: FileItemID) async {
        guard var pending = pendingDeletes[key], pending.backup == backup else { return }
        if activeWrites[key, default: 0] > 0 || replacementBufferIsOpen(for: pending) {
            // The replacement decides: finished, the backup goes; failed, it comes back.
            pending.timer = graceTimer(key, backup: backup)
            pendingDeletes[key] = pending
            return
        }
        await finishPendingDelete(key)
    }

    /// Whether the extension still holds a write buffer for a file of this
    /// name in this folder (Finder copying the replacement in). Folder paths
    /// are best effort; without one any folder of the storage counts.
    private func replacementBufferIsOpen(for pending: PendingDelete) -> Bool {
        guard let bufferDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: bufferDirectory.path(percentEncoded: false))
        else { return false }
        let wanted = pending.originalName.lowercased()
        let suffix = "." + WriteBufferManifest.fileExtension
        for name in names where name.hasSuffix(suffix) {
            guard let data = try? Data(contentsOf: bufferDirectory.appending(path: name)),
                  let manifest = try? JSONDecoder().decode(WriteBufferManifest.self, from: data),
                  manifest.state == .writing,
                  manifest.volume.deviceID == pending.parent.deviceID.volumeKey,
                  manifest.volume.storageID == pending.parent.storageID,
                  manifest.fileName.lowercased() == wanted,
                  pending.path == nil || manifest.folderPath == pending.path
            else { continue }
            let buffer = String(name.dropLast(suffix.count))
            if FinderIPC.isValidBufferName(buffer), WriteBufferLock.isHeld(bufferDirectory.appending(path: buffer)) { return true }
        }
        return false
    }

    private func finishPendingDelete(_ key: String) async {
        guard let pending = pendingDeletes.removeValue(forKey: key) else { return }
        pending.timer.cancel()
        do throws(DeviceError) {
            try await pending.fileSystem.delete(pending.backup)
            journal.remove(pending.journalEntry)
        } catch where error == .objectNotFound {
            journal.remove(pending.journalEntry)
        } catch {
            Log.finder.error("deferred delete failed: \(error.localizationKey, privacy: .public)")
        }
    }

    /// The replacement failed: the deleted original comes back.
    private func restorePendingDelete(_ key: String) async {
        guard let pending = pendingDeletes.removeValue(forKey: key) else { return }
        pending.timer.cancel()
        if (try? await pending.fileSystem.rename(pending.backup, to: pending.originalName)) == nil {
            Log.finder.error("could not restore deleted \(pending.originalName, privacy: .private)")
        } else {
            journal.remove(pending.journalEntry)
            Log.finder.info("restored \(pending.originalName, privacy: .private) after a failed replacement")
        }
    }

    // MARK: - Helpers

    /// Counts `request` as a write to `key` from now until it is answered,
    /// including while it waits for earlier requests.
    private func tracking<T: Sendable>(_ key: String, _ request: @autoclosure () async throws(FinderIPCError) -> T)
        async throws(FinderIPCError) -> T {
        activeWrites[key, default: 0] += 1
        defer {
            activeWrites[key, default: 1] -= 1
            if activeWrites[key] == 0 { activeWrites[key] = nil }
        }
        return try await request()
    }

    /// Runs one request after all earlier ones finished.
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async throws(DeviceError) -> T) async throws(FinderIPCError) -> T {
        let previous = tail
        let task = Task { @MainActor () -> Result<T, DeviceError> in
            await previous?.value
            do throws(DeviceError) {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }
        tail = Task { _ = await task.value }
        switch await task.value {
        case .success(let value): return value
        case .failure(let error): throw FinderIPCError(code: error.posixCode, message: error.localizationKey)
        }
    }

    private static func validate(_ name: String) throws(DeviceError) {
        if let error = FileNameRules.validationError(for: name) { throw error }
    }

    /// Visible object called `name` (case-insensitive, like Android storage).
    private static func existing(named name: String, in parent: FileItemID, fs: any DeviceFileSystem) async throws(DeviceError) -> FileItem? {
        let wanted = name.lowercased()
        return try await fs.contents(of: parent).first { !FileNameRules.isTemporary($0.name) && $0.name.lowercased() == wanted }
    }

    /// The file `name` would replace; a folder or an object the extension
    /// did not mean to replace is a conflict.
    private static func conflict(named name: String, in parent: FileItemID, ignoring object: FileItemID, replacing: UInt32?,
                                 fs: any DeviceFileSystem) async throws(DeviceError) -> FileItem? {
        guard let existing = try await existing(named: name, in: parent, fs: fs), existing.id != object else { return nil }
        guard !existing.isFolder, existing.id.objectID == replacing else { throw .nameConflict(name: name) }
        return existing
    }

    private static func keyPrefix(_ folder: FileItemID) -> String {
        "\(folder.deviceID.rawValue)|\(folder.storageID)|\(folder.objectID)|"
    }

    private static func key(_ parent: FileItemID, _ name: String) -> String {
        keyPrefix(parent) + name.lowercased()
    }
}
