import Foundation

/// Android → Finder (or any other app) drag. The drag carries a file promise;
/// when the receiving app accepts the drop it asks for the file, which is then
/// downloaded through the transfer queue (progress, cancel, size check) into a
/// private folder and handed over from there. The system copies it to the
/// drop location, so the private copy is only kept for a while.
@MainActor
final class DeviceDragExporter {
    private let transfers: TransferManager
    let directory: URL
    /// Private copies older than this are removed before the next export.
    static let keepTime: TimeInterval = 30 * 60
    /// A multi-item drop asks for every item at once; requests arriving within
    /// this window become one transfer job (one row in the transfer list).
    let gatherDelay: Duration

    /// Items downloaded together into one private folder.
    @MainActor
    private final class Batch {
        let folder: URL
        let deviceID: DeviceID
        let generation: UInt64
        var items: [DeviceItemRef] = []
        /// Names already in the folder (case-insensitive, like the device).
        var names: Set<String> = []
        var job: TransferJob?
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []

        init(folder: URL, deviceID: DeviceID, generation: UInt64) {
            self.folder = folder
            self.deviceID = deviceID
            self.generation = generation
        }
    }

    private var gathering: [Batch] = []

    init(transfers: TransferManager,
         directory: URL = FileManager.default.temporaryDirectory.appending(path: "PhoneBridgeDrag", directoryHint: .isDirectory),
         gatherDelay: Duration = .milliseconds(150)) {
        self.transfers = transfers
        self.directory = directory
        self.gatherDelay = gatherDelay
    }

    /// Downloads `item` (file or folder) and returns where it now is.
    func export(_ item: DeviceItemRef, generation: UInt64) async throws(DeviceError) -> URL {
        let batch = try batch(for: item, generation: generation)
        batch.items.append(item)
        batch.names.insert(item.name.lowercased())
        await withCheckedContinuation { batch.waiters.append($0) }

        let url = try LocalFileIO.child(of: batch.folder, named: item.name, isDirectory: item.isFolder)
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        switch batch.job?.state {
        case .completed? where exists:
            return url
        case .failed(let error)?:
            // Files arrive whole (staging + rename), so one that is there is
            // complete even if a later item failed; a folder may be partial.
            if exists, !item.isFolder { return url }
            throw error
        default:
            if exists, !item.isFolder, batch.job?.state != .cancelled { return url }
            throw .cancelled
        }
    }

    /// The gathering batch this item can join, or a new one.
    private func batch(for item: DeviceItemRef, generation: UInt64) throws(DeviceError) -> Batch {
        let deviceID = item.id.deviceID
        if let open = gathering.first(where: { $0.deviceID == deviceID && $0.generation == generation
                                                && !$0.names.contains(item.name.lowercased()) }) {
            return open
        }
        removeOld()
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw TransferManager.mapLocal(error, url: folder, writing: true)
        }
        let batch = Batch(folder: folder, deviceID: deviceID, generation: generation)
        gathering.append(batch)
        Task { [gatherDelay] in
            try? await Task.sleep(for: gatherDelay)
            await self.run(batch)
        }
        return batch
    }

    private func run(_ batch: Batch) async {
        gathering.removeAll { $0 === batch }
        let folders = batch.items.filter(\.isFolder).count
        Log.transfer.info("drag export of \(batch.items.count) item(s) (\(folders) folder(s)) requested")
        let job = transfers.enqueue(.download(items: batch.items, generation: batch.generation, destination: batch.folder,
                                              deleteSourceAfter: false),
                                    destinationName: batch.folder.lastPathComponent, isDragExport: true)
        batch.job = job
        await transfers.waitUntilFinished(job)
        let delivered = batch.items.contains { item in
            guard !item.isFolder, let url = try? LocalFileIO.child(of: batch.folder, named: item.name) else { return false }
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
        if job.state != .completed, !delivered {
            try? FileManager.default.removeItem(at: batch.folder)
        }
        batch.finished = true
        let waiters = batch.waiters
        batch.waiters = []
        waiters.forEach { $0.resume() }
    }

    /// Removes private copies older than `keepTime` (all of them at launch).
    func removeOld(olderThan age: TimeInterval = keepTime, now: Date = Date()) {
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: Set(keys)))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) >= age {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
