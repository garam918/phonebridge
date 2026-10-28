import Foundation
import Observation

/// Serial transfer queue between the Mac and Android devices.
///
/// Safety rules every operation follows:
/// - Downloads land in a hidden staging file next to the destination, are
///   size-verified, and only then moved (or atomically swapped) into place.
/// - Uploads land under a unique staging name on the device, are verified via
///   object metadata, and are renamed into place; an existing file is renamed
///   aside first and restored if anything fails, so it is never lost.
///   Devices without MTP rename never overwrite (they get "keep both").
/// - Free space is checked before the first byte moves.
/// - Failed or cancelled transfers remove their own staging files/objects,
///   never anything else (staging names are unique).
/// - Item handles are re-resolved by path when a job is retried after a
///   reconnect.
@MainActor
@Observable
final class TransferManager {
    private(set) var jobs: [TransferJob] = []
    private(set) var pendingConflict: TransferConflict?
    private(set) var currentSpeed: Double = 0

    /// Overrides the UI prompt (tests, automation).
    @ObservationIgnored var conflictResolver: ((TransferConflict) async -> ConflictDecision)?
    @ObservationIgnored var onJobFinished: ((TransferJob) -> Void)?

    @ObservationIgnored private let fileSystemProvider: (DeviceID) -> (any DeviceFileSystem)?
    @ObservationIgnored private let volume: any LocalVolumeInspecting
    @ObservationIgnored private let scratchDirectory: URL
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<ConflictDecision, Never>?
    @ObservationIgnored private var finishWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    /// Head room kept free on the Mac beyond the bytes being downloaded.
    static let localSpaceMargin: UInt64 = 64 * 1024 * 1024

    /// Staging objects and backups in flight, cleaned in a later session (W3).
    let journal: DeviceLeftoverJournal
    /// Download staging files on the Mac, removed at the next launch after a crash.
    let localJournal: LocalStagingJournal

    init(fileSystemProvider: @escaping (DeviceID) -> (any DeviceFileSystem)?,
         volume: any LocalVolumeInspecting = SystemLocalVolume(),
         scratchDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "PhoneBridgeTransfers"),
         journal: DeviceLeftoverJournal = DeviceLeftoverJournal(fileURL: nil),
         localJournal: LocalStagingJournal = LocalStagingJournal(fileURL: nil)) {
        self.fileSystemProvider = fileSystemProvider
        self.volume = volume
        self.scratchDirectory = scratchDirectory
        self.journal = journal
        self.localJournal = localJournal
    }

    // MARK: - Queue state

    var activeJobs: [TransferJob] { jobs.filter { !$0.state.isFinished } }
    var runningJob: TransferJob? { jobs.first { $0.state == .running } }
    var failedJobs: [TransferJob] {
        jobs.filter { if case .failed = $0.state { true } else { false } }
    }

    /// Progress over all unfinished jobs, nil while nothing is measurable.
    var overallFraction: Double? {
        let active = activeJobs
        let total = active.reduce(UInt64(0)) { $0 + $1.totalBytes }
        if total > 0 {
            return min(1, Double(active.reduce(UInt64(0)) { $0 + $1.transferredBytes }) / Double(total))
        }
        return active.isEmpty ? nil : active.compactMap(\.fractionCompleted).first
    }

    var overallTransferredBytes: UInt64 { activeJobs.reduce(0) { $0 + $1.transferredBytes } }
    var overallTotalBytes: UInt64 { activeJobs.reduce(0) { $0 + $1.totalBytes } }

    /// Seconds left for the running jobs at the current speed.
    var estimatedSecondsRemaining: Double? {
        guard currentSpeed > 1, overallTotalBytes > overallTransferredBytes else { return nil }
        return Double(overallTotalBytes - overallTransferredBytes) / currentSpeed
    }

    // MARK: - Commands

    @discardableResult
    func enqueue(_ request: TransferRequest, destinationName: String, isDragExport: Bool = false) -> TransferJob {
        let job = TransferJob(request: request, destinationName: destinationName, isDragExport: isDragExport)
        jobs.append(job)
        Log.transfer.info("queued \(job.kind.rawValue, privacy: .public) of \(job.itemCount) item(s) → \(destinationName, privacy: .private)")
        startWorkerIfNeeded()
        return job
    }

    func cancel(_ job: TransferJob) {
        guard !job.state.isFinished else { return }
        job.cancelRequested = true
        job.progress?.cancel()
        if job.state == .queued {
            job.state = .cancelled
            finished(job)
        } else if pendingConflict != nil, runningJob === job {
            answerConflict(.always(.skip))
        }
    }

    func cancelAll() {
        for job in activeJobs { cancel(job) }
    }

    /// Re-queues a failed or cancelled job as a new job (fresh progress).
    @discardableResult
    func retry(_ job: TransferJob) -> TransferJob? {
        guard job.canRetry else { return nil }
        jobs.removeAll { $0 === job }
        return enqueue(job.request, destinationName: job.destinationName)
    }

    func remove(_ job: TransferJob) {
        guard job.state.isFinished else { return }
        jobs.removeAll { $0 === job }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    func answerConflict(_ decision: ConflictDecision) {
        pendingConflict = nil
        let continuation = conflictContinuation
        conflictContinuation = nil
        continuation?.resume(returning: decision)
    }

    /// Waits until `job` is completed, failed or cancelled.
    func waitUntilFinished(_ job: TransferJob) async {
        guard !job.state.isFinished else { return }
        await withCheckedContinuation { finishWaiters[job.id, default: []].append($0) }
    }

    private func finished(_ job: TransferJob) {
        onJobFinished?(job)
        finishWaiters.removeValue(forKey: job.id)?.forEach { $0.resume() }
    }

    /// Waits until the queue is empty (tests, app termination).
    func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while let job = jobs.first(where: { $0.state == .queued }) {
            await execute(job)
        }
        currentSpeed = 0
        worker = nil
    }

    private func execute(_ job: TransferJob) async {
        job.state = .running
        let outcome: TransferJobState
        do throws(DeviceError) {
            guard let fileSystem = fileSystemProvider(job.deviceID) else { throw .disconnected }
            let context = JobContext(job: job, fileSystem: fileSystem)
            switch job.request {
            case let .download(items, generation, destination, deleteSource):
                try await runDownload(items: items, generation: generation, destination: destination,
                                      deleteSource: deleteSource, context: context)
            case let .upload(sources, destination, generation, removeSource):
                try await runUpload(sources: sources, destination: destination, generation: generation,
                                    removeSource: removeSource, context: context)
            case let .deviceCopy(items, destination, generation, move):
                try await runDeviceCopy(items: items, destination: destination, generation: generation,
                                        move: move, context: context)
            case let .delete(items, generation):
                try await runDelete(items: items, generation: generation, context: context)
            }
            outcome = job.cancelRequested ? .cancelled : .completed
        } catch {
            outcome = (error == .cancelled || job.cancelRequested) ? .cancelled : .failed(error)
        }
        job.state = outcome
        job.currentName = nil
        job.currentBytes = 0
        job.currentTotal = 0
        job.bytesPerSecond = 0
        job.progress = nil
        switch outcome {
        case .failed(let error):
            Log.transfer.error("\(job.kind.rawValue, privacy: .public) failed: \(error.localizationKey, privacy: .public) \(error.logDetail ?? "", privacy: .public)")
        default:
            Log.transfer.info("\(job.kind.rawValue, privacy: .public) finished: \(String(describing: outcome), privacy: .public), files \(job.finishedFiles)/\(job.totalFiles), skipped \(job.skippedFiles)")
        }
        finished(job)
    }

    // MARK: - Download (device → Mac)

    private func runDownload(items: [DeviceItemRef], generation: UInt64, destination: URL, deleteSource: Bool,
                             context: JobContext) async throws(DeviceError) {
        let job = context.job
        let fs = context.fileSystem
        try Self.requireWritableDirectory(destination)

        var plans: [(top: FileItem, entries: [RemoteTreeEntry])] = []
        for ref in items {
            try Self.checkCancelled(job)
            let top = try await resolve(ref, generation: generation, in: fs)
            plans.append((top, try await walk(top, in: fs, job: job)))
        }
        let files = plans.flatMap(\.entries).filter { !$0.item.isFolder }
        job.totalFiles = files.count
        job.totalBytes = files.reduce(0) { $0 + ($1.item.size ?? 0) }

        if let available = volume.availableCapacity(for: destination),
           available < job.totalBytes + Self.localSpaceMargin {
            throw .insufficientLocalSpace(required: job.totalBytes, available: available)
        }

        for plan in plans {
            try Self.checkCancelled(job)
            let fileCount = plan.entries.filter { !$0.item.isFolder }.count
            guard let target = try await localTarget(for: plan.top, in: destination, context: context) else {
                job.skippedFiles += fileCount
                continue
            }
            var complete = true
            if plan.top.isFolder {
                try Self.createLocalDirectory(target.url)
                context.recordLocalWrite(target.url)
                for entry in plan.entries.dropFirst() {
                    try Self.checkCancelled(job)
                    let url = try LocalFileIO.descendant(of: target.url, path: entry.relative)
                    if entry.item.isFolder {
                        try Self.createLocalDirectory(url)
                        continue
                    }
                    guard let fileTarget = try await localTarget(for: entry.item, at: url, context: context) else {
                        job.skippedFiles += 1
                        complete = false
                        continue
                    }
                    try await downloadFile(entry.item, to: fileTarget.url, replace: fileTarget.replace, context: context)
                    job.finishedFiles += 1
                }
            } else {
                try await downloadFile(plan.top, to: target.url, replace: target.replace, context: context)
                job.finishedFiles += 1
            }
            if deleteSource && complete {
                try await deleteMovedEntries(plan.entries, in: fs, job: job)
            }
        }
    }

    /// Decides where a downloaded item goes when its name already exists.
    private func localTarget(for item: FileItem, in directory: URL, context: JobContext) async throws(DeviceError)
        -> (url: URL, replace: Bool)? {
        try await localTarget(for: item, at: try LocalFileIO.child(of: directory, named: item.name, isDirectory: item.isFolder),
                              context: context)
    }

    private func localTarget(for item: FileItem, at url: URL, context: JobContext) async throws(DeviceError)
        -> (url: URL, replace: Bool)? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            return (url, false)
        }
        if context.wroteLocally(url) {
            // Two items of this job land on one Mac name (the same name from
            // different folders, or names that differ only in case or Unicode
            // form). Replacing would destroy the first one, and a move would
            // then delete both sources.
            return (Self.uniqueLocalURL(for: url), false)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let conflict = TransferConflict(
            kind: context.job.kind, name: item.name, isFolder: item.isFolder,
            destinationName: url.deletingLastPathComponent().lastPathComponent,
            existingSize: isDirectory.boolValue ? nil : (attributes?[.size] as? NSNumber)?.uint64Value,
            existingModified: attributes?[.modificationDate] as? Date,
            incomingSize: item.size, incomingModified: item.modified,
            canReplace: isDirectory.boolValue == item.isFolder)
        switch try await decide(conflict, context: context) {
        case .skip:
            return nil
        case .keepBoth:
            return (Self.uniqueLocalURL(for: url), false)
        case .replace:
            // Folders merge into the existing folder.
            return (url, !item.isFolder)
        }
    }

    private func downloadFile(_ remote: FileItem, to finalURL: URL, replace: Bool, context: JobContext) async throws(DeviceError) {
        let job = context.job
        let stagingURL = finalURL.deletingLastPathComponent().appending(path: FileNameRules.temporaryName(suffix: "download"))
        let progress = beginFile(remote.name, size: remote.size ?? 0, job: job)
        let ticker = track(progress, job: job)
        let entry = localJournal.record(stagingURL)
        defer {
            ticker.cancel()
            localJournal.remove(entry)
        }

        do throws(DeviceError) {
            try await context.fileSystem.download(remote.id, to: stagingURL, progress: progress)
            try Self.checkCancelled(job)
            let actual = LocalFileIO.fileSize(stagingURL) ?? 0
            if let expected = remote.size, actual != expected {
                throw .verificationFailed(expected: expected, actual: actual)
            }
            try Self.commitLocal(stagingURL, to: finalURL, replace: replace)
            context.recordLocalWrite(finalURL)
            if let modified = remote.modified {
                try? FileManager.default.setAttributes([.modificationDate: modified],
                                                       ofItemAtPath: finalURL.path(percentEncoded: false))
            }
            job.finishedBytes += actual
            job.currentBytes = 0
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            job.currentBytes = 0
            throw error
        }
    }

    // MARK: - Upload (Mac → device)

    private func runUpload(sources: [URL], destination: DeviceFolderRef, generation: UInt64, removeSource: Bool,
                           context: JobContext) async throws(DeviceError) {
        let job = context.job
        let fs = context.fileSystem
        guard fs.capabilities.canWrite else { throw .unsupportedOperation }
        let folder = try await resolveFolder(destination, generation: generation, in: fs)
        let storage = try await fs.storages().first { $0.id == folder.storageID }
        if storage?.isReadOnly == true { throw .readOnlyStorage }

        let planned = await Task.detached { Result { () throws(DeviceError) in try Self.planLocal(sources) } }.value
        let plans = try planned.get()
        job.totalFiles = plans.reduce(0) { $0 + $1.fileCount }
        job.totalBytes = plans.reduce(0) { $0 + $1.totalBytes }
        if let free = storage?.freeSpace, free < job.totalBytes {
            throw .insufficientDeviceSpace(required: job.totalBytes, available: free)
        }

        var listings = ListingCache(fileSystem: fs)
        // Objects this job created. Two Mac names can become one device name
        // (sanitized characters, case), and replacing would then destroy the
        // first upload — and a move would delete both sources (as `wroteLocally`).
        var writtenHere: Set<FileItemID> = []
        for plan in plans {
            try Self.checkCancelled(job)
            let name = FileNameRules.sanitizedForDevice(plan.top.url.lastPathComponent)
            let siblings = try await listings.items(in: folder)
            var targetName = name
            var replaceTarget: FileItem?
            if let existing = siblings.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
               writtenHere.contains(existing.id) {
                if existing.isFolder && plan.top.isDirectory {
                    replaceTarget = existing // merge into the folder made a moment ago
                } else {
                    targetName = FileNameRules.uniqueName(for: name, existing: Set(siblings.map(\.name)))
                }
            } else if let existing = siblings.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let conflict = TransferConflict(
                    kind: job.kind, name: name, isFolder: plan.top.isDirectory, destinationName: job.destinationName,
                    existingSize: existing.size, existingModified: existing.modified,
                    incomingSize: plan.top.isDirectory ? nil : plan.top.size, incomingModified: plan.top.modified,
                    canReplace: existing.isFolder == plan.top.isDirectory && (plan.top.isDirectory || fs.capabilities.canRename))
                switch try await decide(conflict, context: context) {
                case .skip:
                    job.skippedFiles += plan.fileCount
                    continue
                case .keepBoth:
                    targetName = FileNameRules.uniqueName(for: name, existing: Set(siblings.map(\.name)))
                case .replace:
                    replaceTarget = existing
                }
            }

            var complete = true
            if plan.top.isDirectory {
                let topFolder: FileItemID
                if let replaceTarget, replaceTarget.isFolder {
                    topFolder = replaceTarget.id // merge
                } else {
                    let created = try await fs.createFolder(named: targetName, in: folder)
                    listings.add(created, to: folder)
                    writtenHere.insert(created.id)
                    topFolder = created.id
                }
                var folderIDs: [[String]: FileItemID] = [[]: topFolder]
                for entry in plan.entries {
                    try Self.checkCancelled(job)
                    guard let parent = folderIDs[Array(entry.relative.dropLast())] else { continue }
                    let entryName = FileNameRules.sanitizedForDevice(entry.relative.last ?? entry.url.lastPathComponent)
                    let siblings = try await listings.items(in: parent)
                    let clash = siblings.first { $0.name.caseInsensitiveCompare(entryName) == .orderedSame }
                    if entry.isDirectory {
                        if let clash, clash.isFolder {
                            folderIDs[entry.relative] = clash.id
                        } else {
                            let folderName = clash == nil ? entryName
                                : FileNameRules.uniqueName(for: entryName, existing: Set(siblings.map(\.name)))
                            let created = try await fs.createFolder(named: folderName, in: parent)
                            listings.add(created, to: parent)
                            writtenHere.insert(created.id)
                            folderIDs[entry.relative] = created.id
                        }
                        continue
                    }
                    var finalName = entryName
                    var replacing: FileItem?
                    if let clash, writtenHere.contains(clash.id) {
                        finalName = FileNameRules.uniqueName(for: entryName, existing: Set(siblings.map(\.name)))
                    } else if let clash {
                        let conflict = TransferConflict(
                            kind: job.kind, name: entryName, isFolder: false, destinationName: entry.relative.dropLast().last ?? targetName,
                            existingSize: clash.size, existingModified: clash.modified,
                            incomingSize: entry.size, incomingModified: entry.modified,
                            canReplace: !clash.isFolder && fs.capabilities.canRename)
                        switch try await decide(conflict, context: context) {
                        case .skip:
                            job.skippedFiles += 1
                            complete = false
                            continue
                        case .keepBoth:
                            finalName = FileNameRules.uniqueName(for: entryName, existing: Set(siblings.map(\.name)))
                        case .replace:
                            replacing = clash
                        }
                    }
                    let uploaded = try await uploadFile(entry, named: finalName, into: parent, replacing: replacing, context: context)
                    listings.replace(replacing, with: uploaded, in: parent)
                    writtenHere.insert(uploaded.id)
                    job.finishedFiles += 1
                }
            } else {
                let uploaded = try await uploadFile(plan.top, named: targetName, into: folder, path: destination.path,
                                                    replacing: replaceTarget, context: context)
                listings.replace(replaceTarget, with: uploaded, in: folder)
                writtenHere.insert(uploaded.id)
                job.finishedFiles += 1
            }

            if removeSource && complete {
                do {
                    try FileManager.default.trashItem(at: plan.top.url, resultingItemURL: nil)
                } catch {
                    job.warnings.append(plan.top.url.lastPathComponent)
                }
            }
        }
    }

    /// Stages, verifies and swaps one file into place on the device.
    @discardableResult
    private func uploadFile(_ entry: LocalEntry, named finalName: String, into folder: FileItemID, path: [String]? = nil,
                            replacing existing: FileItem?, context: JobContext) async throws(DeviceError) -> FileItem {
        let job = context.job
        let progress = beginFile(entry.url.lastPathComponent, size: entry.size, job: job)
        let ticker = track(progress, job: job)
        defer {
            ticker.cancel()
            job.currentBytes = 0
        }
        let writer = SafeDeviceWrite(fileSystem: context.fileSystem, journal: journal,
                                     onLeftover: { job.warnings.append($0) },
                                     checkpoint: { () throws(DeviceError) in try Self.checkCancelled(job) })
        let uploaded = try await writer.upload(entry.url, size: entry.size, named: finalName, into: folder, path: path,
                                               replacing: existing, modified: entry.modified, progress: progress)
        job.finishedBytes += entry.size
        return uploaded
    }

    // MARK: - Copy / move on the device

    private func runDeviceCopy(items: [DeviceItemRef], destination: DeviceFolderRef, generation: UInt64, move: Bool,
                               context: JobContext) async throws(DeviceError) {
        let job = context.job
        let fs = context.fileSystem
        guard fs.capabilities.canWrite else { throw .unsupportedOperation }
        let target = try await resolveFolder(destination, generation: generation, in: fs)
        job.totalFiles = items.count

        for ref in items {
            try Self.checkCancelled(job)
            let item = try await resolve(ref, generation: generation, in: fs)
            let sameStorage = item.id.storageID == target.storageID
            if item.isFolder, sameStorage, destination.path.starts(with: ref.path) {
                throw .invalidDestination
            }
            let sameFolder = sameStorage && Array(ref.path.dropLast()) == destination.path
            if sameFolder && move {
                job.skippedFiles += 1
                continue
            }
            let siblings = try await fs.contents(of: target)
            var targetName = item.name
            var replaceTarget: FileItem?
            if sameFolder {
                targetName = FileNameRules.uniqueName(for: item.name, existing: Set(siblings.map(\.name)))
            } else if let clash = siblings.first(where: { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }) {
                let conflict = TransferConflict(
                    kind: job.kind, name: item.name, isFolder: item.isFolder, destinationName: job.destinationName,
                    existingSize: clash.size, existingModified: clash.modified,
                    incomingSize: item.size, incomingModified: item.modified,
                    canReplace: !item.isFolder && !clash.isFolder && fs.capabilities.canRename)
                switch try await decide(conflict, context: context) {
                case .skip:
                    job.skippedFiles += 1
                    continue
                case .keepBoth:
                    targetName = FileNameRules.uniqueName(for: item.name, existing: Set(siblings.map(\.name)))
                case .replace:
                    replaceTarget = clash
                }
            }

            job.currentName = item.name
            let native = move ? fs.capabilities.canMoveNatively : fs.capabilities.canCopyNatively
            var copiedEntries: [RemoteTreeEntry]?
            // The file being replaced is set aside under a journaled backup
            // name, so an unplug or a crash in between restores it (D36).
            let writer = SafeDeviceWrite(fileSystem: fs, journal: journal, onLeftover: { job.warnings.append($0) })
            _ = try await writer.swap(replaceTarget, in: target, path: destination.path) { () throws(DeviceError) in
                if native && targetName == item.name {
                    return move ? try await fs.move(item.id, to: target) : try await fs.copy(item.id, to: target)
                }
                let copied = try await copyThroughMac(item, named: targetName, into: target, context: context)
                copiedEntries = copied.entries
                return copied.top
            }
            if move, let copiedEntries {
                // Only what was copied; anything that appeared meanwhile stays.
                try await deleteMovedEntries(copiedEntries, in: fs, job: job)
            }
            job.finishedFiles += 1
        }
    }

    /// Copy fallback when the device lacks CopyObject/MoveObject (or the copy
    /// needs a new name): download into a scratch folder, upload, verify.
    /// Returns the new top-level item and the source entries that were copied.
    private func copyThroughMac(_ item: FileItem, named name: String, into folder: FileItemID,
                                context: JobContext) async throws(DeviceError) -> (top: FileItem, entries: [RemoteTreeEntry]) {
        let fs = context.fileSystem
        let scratch = scratchDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try Self.createLocalDirectory(scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let entries = try await walk(item, in: fs, job: context.job)
        let localRoot = scratch.appending(path: "item")
        for entry in entries {
            try Self.checkCancelled(context.job)
            let url = try LocalFileIO.descendant(of: localRoot, path: entry.relative)
            if entry.item.isFolder {
                try Self.createLocalDirectory(url)
            } else {
                try await downloadFile(entry.item, to: url, replace: false, context: context)
            }
        }

        if item.isFolder {
            let top = try await fs.createFolder(named: name, in: folder)
            var folderIDs: [[String]: FileItemID] = [[]: top.id]
            for entry in entries.dropFirst() {
                try Self.checkCancelled(context.job)
                guard let parent = folderIDs[Array(entry.relative.dropLast())] else { continue }
                if entry.item.isFolder {
                    folderIDs[entry.relative] = try await fs.createFolder(named: entry.item.name, in: parent).id
                } else {
                    let url = try LocalFileIO.descendant(of: localRoot, path: entry.relative)
                    let local = LocalEntry(url: url, relative: entry.relative, isDirectory: false,
                                           size: entry.item.size ?? LocalFileIO.fileSize(url) ?? 0, modified: entry.item.modified)
                    try await uploadFile(local, named: entry.item.name, into: parent, replacing: nil, context: context)
                }
            }
            return (top, entries)
        }
        let local = LocalEntry(url: localRoot, relative: [], isDirectory: false,
                               size: item.size ?? LocalFileIO.fileSize(localRoot) ?? 0, modified: item.modified)
        return (try await uploadFile(local, named: name, into: folder, replacing: nil, context: context), entries)
    }

    // MARK: - Delete

    private func runDelete(items: [DeviceItemRef], generation: UInt64, context: JobContext) async throws(DeviceError) {
        let job = context.job
        let fs = context.fileSystem
        guard fs.capabilities.canDelete else { throw .unsupportedOperation }
        var trees: [[RemoteTreeEntry]] = []
        for ref in items {
            try Self.checkCancelled(job)
            let item = try await resolve(ref, generation: generation, in: fs)
            trees.append(try await walk(item, in: fs, job: job))
        }
        job.totalFiles = trees.reduce(0) { $0 + $1.count }
        for tree in trees {
            try await deleteEntries(tree, in: fs, job: job, countProgress: true)
        }
    }

    /// Deletes a walked tree bottom-up (children before their folder).
    private func deleteEntries(_ entries: [RemoteTreeEntry], in fs: any DeviceFileSystem, job: TransferJob,
                               countProgress: Bool) async throws(DeviceError) {
        for entry in entries.reversed() {
            try Self.checkCancelled(job)
            job.currentName = entry.item.name
            try await fs.delete(entry.item.id)
            if countProgress { job.finishedFiles += 1 }
        }
    }

    /// Removes the sources of a move once they were copied, bottom-up. A
    /// folder is deleted only when the device reports it empty: Android
    /// deletes folders recursively, so anything not in `entries` (added during
    /// the transfer, hidden staging objects, objects libmtp could not list)
    /// would otherwise go without having been copied. Such folders stay.
    private func deleteMovedEntries(_ entries: [RemoteTreeEntry], in fs: any DeviceFileSystem,
                                    job: TransferJob) async throws(DeviceError) {
        for entry in entries.reversed() {
            try Self.checkCancelled(job)
            job.currentName = entry.item.name
            if entry.item.isFolder, try await fs.childCount(of: entry.item.id) > 0 {
                Log.transfer.notice("kept a moved folder that is not empty: \(entry.item.name, privacy: .private)")
                job.keptFolders.append(entry.item.name)
                continue
            }
            try await fs.delete(entry.item.id)
        }
    }

    // MARK: - Conflicts

    private func decide(_ conflict: TransferConflict, context: JobContext) async throws(DeviceError) -> ConflictAction {
        // A job cancelled while it waited for the device must not open a
        // question nobody will answer (at quit it would block forever).
        try Self.checkCancelled(context.job)
        var action: ConflictAction
        if let standing = context.standingAction {
            action = standing
        } else {
            let decision: ConflictDecision
            if let conflictResolver {
                decision = await conflictResolver(conflict)
            } else {
                decision = await withCheckedContinuation { continuation in
                    conflictContinuation = continuation
                    pendingConflict = conflict
                }
            }
            try Self.checkCancelled(context.job)
            action = decision.action
            if decision.applyToAll { context.standingAction = action }
        }
        if action == .replace && !conflict.canReplace { action = .keepBoth }
        return action
    }

    // MARK: - Resolution

    private func resolve(_ ref: DeviceItemRef, generation: UInt64, in fs: any DeviceFileSystem) async throws(DeviceError) -> FileItem {
        if fs.generation == generation { return ref.fileItem }
        return try await resolvePath(ref.path, storageID: ref.id.storageID, in: fs)
    }

    private func resolveFolder(_ ref: DeviceFolderRef, generation: UInt64, in fs: any DeviceFileSystem) async throws(DeviceError) -> FileItemID {
        if fs.generation == generation { return ref.id }
        if ref.path.isEmpty { return .root(deviceID: fs.deviceID, storageID: ref.id.storageID) }
        let folder = try await resolvePath(ref.path, storageID: ref.id.storageID, in: fs)
        guard folder.isFolder else { throw .objectNotFound }
        return folder.id
    }

    private func resolvePath(_ path: [String], storageID: UInt32, in fs: any DeviceFileSystem) async throws(DeviceError) -> FileItem {
        var folder = FileItemID.root(deviceID: fs.deviceID, storageID: storageID)
        var found: FileItem?
        for name in path {
            guard let match = try await fs.contents(of: folder).first(where: { $0.name == name }) else { throw .objectNotFound }
            found = match
            folder = match.id
        }
        guard let found else { throw .objectNotFound }
        return found
    }

    /// The item followed by all descendants, parents before children.
    private func walk(_ item: FileItem, in fs: any DeviceFileSystem, job: TransferJob) async throws(DeviceError) -> [RemoteTreeEntry] {
        var result = [RemoteTreeEntry(item: item, relative: [])]
        guard item.isFolder else { return result }
        var pending: [(FileItemID, [String])] = [(item.id, [])]
        while let (folder, relative) = pending.popLast() {
            try Self.checkCancelled(job)
            for child in try await fs.contents(of: folder) where !FileNameRules.isTemporary(child.name) {
                let path = relative + [child.name]
                result.append(RemoteTreeEntry(item: child, relative: path))
                if child.isFolder { pending.append((child.id, path)) }
            }
        }
        return result
    }

    // MARK: - Progress

    private func beginFile(_ name: String, size: UInt64, job: TransferJob) -> TransferProgress {
        let progress = TransferProgress()
        if job.cancelRequested { progress.cancel() }
        job.progress = progress
        job.currentName = name
        job.currentBytes = 0
        job.currentTotal = size
        return progress
    }

    /// Mirrors a blocking transfer's progress into the job a few times per
    /// second and derives a smoothed speed.
    private func track(_ progress: TransferProgress, job: TransferJob) -> Task<Void, Never> {
        Task { [weak self] in
            let clock = ContinuousClock()
            var lastBytes: UInt64 = 0
            var lastTime = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                // A cancelled ticker must not write a stale sample after the
                // file was already accounted for.
                guard !Task.isCancelled else { break }
                let now = clock.now
                let done = progress.completed
                job.currentBytes = done
                let elapsed = now - lastTime
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                if seconds > 0, done >= lastBytes {
                    let instant = Double(done - lastBytes) / seconds
                    job.bytesPerSecond = job.bytesPerSecond == 0 ? instant : job.bytesPerSecond * 0.7 + instant * 0.3
                    self?.currentSpeed = job.bytesPerSecond
                }
                lastBytes = done
                lastTime = now
            }
        }
    }

    // MARK: - Local helpers

    private static func checkCancelled(_ job: TransferJob) throws(DeviceError) {
        if job.cancelRequested { throw .cancelled }
    }

    private static func requireWritableDirectory(_ url: URL) throws(DeviceError) {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .localWriteFailed(path: path, detail: "not a folder")
        }
        guard FileManager.default.isWritableFile(atPath: path) else { throw .localPermissionDenied(path: path) }
    }

    private static func createLocalDirectory(_ url: URL) throws(DeviceError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw mapLocal(error, url: url, writing: true)
        }
    }

    private static func commitLocal(_ staging: URL, to final: URL, replace: Bool) throws(DeviceError) {
        do {
            if replace, FileManager.default.fileExists(atPath: final.path(percentEncoded: false)) {
                // Atomic swap: the old file disappears only once the new one is in place.
                _ = try FileManager.default.replaceItemAt(final, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: final)
            }
        } catch {
            throw mapLocal(error, url: final, writing: true)
        }
    }

    nonisolated static func uniqueLocalURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return directory.appending(path: FileNameRules.uniqueName(for: url.lastPathComponent, existing: Set(existing)))
    }

    nonisolated static func mapLocal(_ error: any Error, url: URL, writing: Bool) -> DeviceError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return LocalFileIO.mapErrno(Int32(nsError.code), url: url, writing: writing)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return LocalFileIO.mapErrno(Int32(underlying.code), url: url, writing: writing)
        }
        let path = url.path(percentEncoded: false)
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileWriteNoPermission, .fileReadNoPermission, .fileWriteVolumeReadOnly:
            return .localPermissionDenied(path: path)
        case .fileWriteOutOfSpace:
            return .insufficientLocalSpace(required: 0, available: 0)
        default:
            return writing ? .localWriteFailed(path: path, detail: nsError.localizedDescription)
                : .localReadFailed(path: path, detail: nsError.localizedDescription)
        }
    }

    /// Enumerates upload sources off the main actor. Symlinks and Finder
    /// metadata are skipped; unreadable items fail the job before any upload.
    nonisolated static func planLocal(_ sources: [URL]) throws(DeviceError) -> [LocalPlan] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let fileManager = FileManager.default
        var plans: [LocalPlan] = []
        for source in sources {
            let top = try localEntry(source, relative: [], keys: keys)
            guard let top else { continue }
            var plan = LocalPlan(top: top, entries: [])
            if top.isDirectory {
                var enumerationError: (URL, any Error)?
                let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: keys, options: []) { url, error in
                    enumerationError = (url, error)
                    return false
                }
                let baseCount = source.standardizedFileURL.pathComponents.count
                while let url = enumerator?.nextObject() as? URL {
                    let relative = Array(url.standardizedFileURL.pathComponents.dropFirst(baseCount))
                    if let entry = try localEntry(url, relative: relative, keys: keys) {
                        plan.entries.append(entry)
                    }
                }
                if let (url, error) = enumerationError {
                    throw mapLocal(error, url: url, writing: false)
                }
            }
            plans.append(plan)
        }
        return plans
    }

    nonisolated private static func localEntry(_ url: URL, relative: [String], keys: [URLResourceKey]) throws(DeviceError) -> LocalEntry? {
        let path = url.path(percentEncoded: false)
        let name = url.lastPathComponent
        if name == ".DS_Store" || FileNameRules.isTemporary(name) { return nil }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Set(keys))
        } catch {
            throw mapLocal(error, url: url, writing: false)
        }
        if values.isSymbolicLink == true { return nil }
        guard FileManager.default.isReadableFile(atPath: path) else { throw .localPermissionDenied(path: path) }
        let isDirectory = values.isDirectory == true
        return LocalEntry(url: url, relative: relative, isDirectory: isDirectory,
                          size: isDirectory ? 0 : UInt64(max(0, values.fileSize ?? 0)),
                          modified: values.contentModificationDate)
    }
}

// MARK: - Supporting types

@MainActor
private final class JobContext {
    let job: TransferJob
    let fileSystem: any DeviceFileSystem
    /// "Apply to all" answer for the rest of this job.
    var standingAction: ConflictAction?
    /// Mac files and folders this job created (file-system identities, so
    /// case and Unicode-form variants of a name match too).
    private var localWrites: Set<NSObject> = []

    func recordLocalWrite(_ url: URL) {
        if let identity = Self.identity(of: url) { localWrites.insert(identity) }
    }

    func wroteLocally(_ url: URL) -> Bool {
        Self.identity(of: url).map(localWrites.contains) ?? false
    }

    private static func identity(of url: URL) -> NSObject? {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }

    init(job: TransferJob, fileSystem: any DeviceFileSystem) {
        self.job = job
        self.fileSystem = fileSystem
    }
}

private struct RemoteTreeEntry {
    let item: FileItem
    /// Names below the job's top-level item (empty for the item itself).
    let relative: [String]
}

struct LocalEntry: Sendable {
    let url: URL
    /// Path components below the top-level source (empty for the source).
    let relative: [String]
    let isDirectory: Bool
    let size: UInt64
    let modified: Date?
}

struct LocalPlan: Sendable {
    let top: LocalEntry
    var entries: [LocalEntry]

    var fileCount: Int { top.isDirectory ? entries.filter { !$0.isDirectory }.count : 1 }
    var totalBytes: UInt64 { top.isDirectory ? entries.reduce(0) { $0 + $1.size } : top.size }
}

/// Destination folder listings fetched once per job and kept up to date.
@MainActor
private struct ListingCache {
    let fileSystem: any DeviceFileSystem
    private var listings: [FileItemID: [FileItem]] = [:]

    init(fileSystem: any DeviceFileSystem) {
        self.fileSystem = fileSystem
    }

    mutating func items(in folder: FileItemID) async throws(DeviceError) -> [FileItem] {
        if let cached = listings[folder] { return cached }
        let items = try await fileSystem.contents(of: folder)
        listings[folder] = items
        return items
    }

    mutating func add(_ item: FileItem, to folder: FileItemID) {
        listings[folder, default: []].append(item)
    }

    mutating func replace(_ old: FileItem?, with new: FileItem, in folder: FileItemID) {
        if let old { listings[folder]?.removeAll { $0.id == old.id } }
        listings[folder, default: []].append(new)
    }
}
