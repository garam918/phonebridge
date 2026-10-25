import Foundation

/// The one implementation of "put a file on the device without risking the
/// original" (D16, D26), shared by app uploads (`TransferManager`) and Finder
/// writes (`FinderWriteCoordinator`):
///
/// 1. upload under a hidden staging name and check the size the device reports;
/// 2. move an existing file aside under a hidden backup name;
/// 3. rename the staging object to the final name;
/// 4. delete the backup — or, if step 3 failed, rename it back.
///
/// Every hidden object is written to the leftover journal before it exists, so
/// a crash or an unplug in between is cleaned up in the next session (W3).
/// Devices without rename get the final name directly and never replace
/// (callers offer "keep both" instead).
@MainActor
struct SafeDeviceWrite {
    let fileSystem: any DeviceFileSystem
    let journal: DeviceLeftoverJournal
    /// A hidden object that could not be removed or restored (shown to the user).
    var onLeftover: (String) -> Void = { _ in }
    /// Runs after the upload is verified, before anything is replaced
    /// (e.g. a cancel check); throwing removes the staging object.
    var checkpoint: () throws(DeviceError) -> Void = {}

    /// Uploads `source` as `name` into `parent`, replacing `existing` if given.
    func upload(_ source: URL, size: UInt64, named name: String, into parent: FileItemID, path: [String]?,
                replacing existing: FileItem?, modified: Date?, progress: TransferProgress) async throws(DeviceError) -> FileItem {
        let fs = fileSystem
        let staged = fs.capabilities.canRename
        // Without rename an existing file could only be deleted first; refuse
        // rather than risk losing it.
        guard existing == nil || staged else { throw .unsupportedOperation }
        let uploadName = staged ? FileNameRules.temporaryName() : name
        let entry = staged ? journal.record(.staging, named: uploadName, in: parent, path: path, generation: fs.generation) : nil

        var created: FileItem?
        do throws(DeviceError) {
            let uploaded = try await fs.upload(from: source, size: size, named: uploadName, into: parent,
                                               modified: modified, progress: progress)
            created = uploaded
            try checkpoint()
            let verified = try await fs.item(uploaded.id)
            if verified.size != size { throw .verificationFailed(expected: size, actual: verified.size ?? 0) }
        } catch {
            // Unstaged uploads use the final name, which was free before (the
            // caller checked), so a partial object under it is ours.
            if await removeStaged(created?.id, named: uploadName, in: parent) { journal.remove(entry) }
            throw error
        }
        guard staged, let staging = created else { return created! }

        do throws(DeviceError) {
            let placed = try await swap(existing, in: parent, path: path) { () throws(DeviceError) in
                try await fs.rename(staging.id, to: name)
            }
            journal.remove(entry)
            if placed.size != size {
                Log.transfer.error("after rename the device reports \(placed.size ?? 0) of \(size) bytes")
            }
            return placed
        } catch {
            if await removeStaged(staging.id, named: uploadName, in: parent) { journal.remove(entry) }
            throw error
        }
    }

    /// Runs `place` with `existing` moved aside under a backup name; restores
    /// it when `place` fails and deletes it when `place` succeeds.
    func swap(_ existing: FileItem?, in parent: FileItemID, path: [String]?,
              _ place: () async throws(DeviceError) -> FileItem) async throws(DeviceError) -> FileItem {
        guard let existing else { return try await place() }
        let fs = fileSystem
        let backupName = FileNameRules.temporaryName(suffix: "bak")
        let entry = journal.record(.backup, named: backupName, in: parent, path: path, originalName: existing.name,
                                   generation: fs.generation)
        let backup: FileItem
        do throws(DeviceError) {
            backup = try await fs.rename(existing.id, to: backupName)
        } catch {
            journal.remove(entry)
            throw error
        }
        let placed: FileItem
        do throws(DeviceError) {
            placed = try await place()
        } catch {
            if (try? await fs.rename(backup.id, to: existing.name)) == nil {
                // Still in the journal: restored in the next session.
                Log.transfer.error("could not restore \(existing.name, privacy: .private); kept as \(backup.name, privacy: .public)")
                onLeftover(backup.name)
            } else {
                journal.remove(entry)
            }
            throw error
        }
        do throws(DeviceError) {
            try await fs.delete(backup.id)
            journal.remove(entry)
        } catch {
            Log.transfer.error("could not remove backup \(backup.name, privacy: .public): \(error.localizationKey, privacy: .public)")
            onLeftover(backup.name)
        }
        return placed
    }

    /// Best-effort removal of an object this write created. Without an id it
    /// is found by name: a staging name, or (unstaged) a final name that was
    /// free before the upload. true when nothing is left.
    @discardableResult
    func removeStaged(_ id: FileItemID?, named name: String, in parent: FileItemID) async -> Bool {
        do throws(DeviceError) {
            if let id {
                try await fileSystem.delete(id)
            } else {
                for leftover in try await fileSystem.contents(of: parent) where leftover.name == name && !leftover.isFolder {
                    try await fileSystem.delete(leftover.id)
                }
            }
            return true
        } catch where error == .objectNotFound {
            return true
        } catch {
            let shown = FileNameRules.isTemporary(name) ? name : "(file)"
            Log.transfer.error("could not remove staging object \(shown, privacy: .public): \(error.localizationKey, privacy: .public)")
            onLeftover(name)
            return false
        }
    }
}
