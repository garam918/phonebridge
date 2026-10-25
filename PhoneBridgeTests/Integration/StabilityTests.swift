import Foundation
import Testing
@testable import PhoneBridge

/// Release stabilization: repetition and churn that single-scenario tests do
/// not cover. Mock USB + mock MTP; no real hardware.
@MainActor
@Suite("Stability (repetition, churn, queue stress)", .serialized)
struct StabilityTests {
    let monitor = MockUSBMonitor()
    let backend = MockMTPBackend()

    private var pixelID: DeviceID { USBDeviceSnapshot.fixture().logicalID }

    private func makeBroker() -> DeviceBroker {
        var configuration = DeviceBroker.Configuration.fast
        configuration.reconnectGracePeriod = .milliseconds(50)
        let broker = DeviceBroker(monitor: monitor, backend: backend, configuration: configuration)
        broker.start()
        return broker
    }

    @Test(.timeLimit(.minutes(2)))
    func hundredPlugUnplugCyclesCloseEverySession() async throws {
        let broker = makeBroker()
        var generations: [UInt64] = []
        for cycle in 0..<100 {
            let registryID = UInt64(100 + cycle)
            monitor.send(.attached(.fixture(registryID: registryID, address: UInt8(1 + cycle % 120))))
            try await waitUntil { broker.record(for: pixelID)?.state == .connected }
            generations.append(try #require(broker.record(for: pixelID)?.generation))
            #expect(broker.devices.count == 1)
            monitor.send(.detached(registryID: registryID))
            try await waitUntil { broker.record(for: pixelID)?.state != .connected }
        }
        try await waitUntil(timeout: .seconds(5)) { broker.devices.isEmpty && backend.stats.close == backend.stats.open }
        #expect(backend.stats.open == 100)
        #expect(Set(generations).count == 100, "every reconnect is a new generation")
        #expect(backend.stats.mainThread == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func rapidChurnEndsWithExactlyOneOpenSession() async throws {
        let broker = makeBroker()
        // Plug / unplug faster than a session can open (loose connector).
        for cycle in 0..<40 {
            monitor.send(.attached(.fixture(registryID: UInt64(500 + cycle))))
            monitor.send(.detached(registryID: UInt64(500 + cycle)))
        }
        monitor.send(.attached(.fixture(registryID: 999)))
        try await waitUntil(timeout: .seconds(5)) { broker.record(for: pixelID)?.state == .connected }
        try await waitUntil(timeout: .seconds(5)) { backend.stats.open - backend.stats.close == 1 }
        #expect(broker.devices.count == 1)
        #expect(broker.fileSystem(for: pixelID) != nil)

        monitor.send(.detached(registryID: 999))
        try await waitUntil(timeout: .seconds(5)) { broker.devices.isEmpty && backend.stats.open == backend.stats.close }
    }

    @Test(.timeLimit(.minutes(2)))
    func queueStressWithCancellationsLeavesNoStagingAnywhere() async throws {
        let storage = MockDeviceFileSystem.internalStorageID
        let fs = MockDeviceFileSystem(faults: .init(chunkSize: 64 << 10, chunkDelay: .microseconds(200)))
        let local = FileManager.default.temporaryDirectory.appending(path: "PBStability-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let manager = TransferManager(fileSystemProvider: { $0 == fs.deviceID ? fs : nil }, volume: FakeVolume(available: nil),
                                      scratchDirectory: local.appending(path: ".scratch"))
        manager.conflictResolver = { _ in .always(.keepBoth) }

        let root = FileItemID.root(deviceID: fs.deviceID, storageID: storage)
        let download = try #require(try await fs.contents(of: root).first { $0.name == "Download" })
        let files = try await fs.contents(of: download.id).filter { !$0.isFolder }
        let source = local.appending(path: "upload.bin")
        try Data(repeating: 0x5A, count: 3 << 20).write(to: source)
        let destination = DeviceFolderRef(id: download.id, path: ["Download"])

        var jobs: [TransferJob] = []
        for index in 0..<36 {
            let file = files[index % files.count]
            let ref = DeviceItemRef(item: file, parentPath: ["Download"])
            let request: TransferRequest = switch index % 3 {
            case 0: .download(items: [ref], generation: fs.generation, destination: local, deleteSourceAfter: false)
            case 1: .upload(sources: [source], destination: destination, generation: fs.generation, removeSourceAfter: false)
            default: .deviceCopy(items: [ref], destination: destination, generation: fs.generation, move: false)
            }
            jobs.append(manager.enqueue(request, destinationName: "stress"))
            if index % 4 == 3 { manager.cancel(jobs[index - 1]) }
            if index % 7 == 0 { await Task.yield() }
        }
        // Cancel whatever is running mid-way, twice.
        for _ in 0..<2 {
            try await waitUntil(timeout: .seconds(20)) { manager.runningJob != nil }
            if let running = manager.runningJob { manager.cancel(running) }
        }
        await manager.waitUntilIdle()

        #expect(jobs.allSatisfy { $0.state.isFinished })
        let failed = jobs.filter { if case .failed = $0.state { true } else { false } }
        #expect(failed.isEmpty, "\(failed.map(\.state))")
        #expect(jobs.filter { $0.state == .cancelled }.count >= 9)
        #expect(manager.activeJobs.isEmpty && manager.runningJob == nil)

        // No hidden staging object on the device, no staging file on the Mac.
        var pending = [root]
        while let folder = pending.popLast() {
            for child in try await fs.contents(of: folder) {
                #expect(!FileNameRules.isTemporary(child.name), "device leftover")
                if child.isFolder { pending.append(child.id) }
            }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: local.path(percentEncoded: false))
            .filter { $0.hasPrefix(FileNameRules.temporaryPrefix) }
        #expect(leftovers.isEmpty)
    }
}

/// Crash recovery for download staging files on the Mac.
@MainActor
@Suite("Local staging journal (crash recovery)")
struct LocalStagingJournalTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "PBLocalStaging-\(UUID().uuidString)", directoryHint: .isDirectory)
    var journalURL: URL { folder.appending(path: "journal.json") }

    @Test func stagingLeftByACrashedLaunchIsRemovedAtTheNextLaunch() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let staging = folder.appending(path: FileNameRules.temporaryName(suffix: "download"))
        let userFile = folder.appending(path: "사진.jpg")
        try Data("partial".utf8).write(to: staging)
        try Data("mine".utf8).write(to: userFile)

        // Launch 1 records the staging file and "crashes" (never removes the entry).
        let crashed = LocalStagingJournal(fileURL: journalURL, run: UUID())
        #expect(crashed.record(staging) != nil)
        #expect(crashed.record(userFile) == nil, "only PhoneBridge temporary names are ever recorded")

        // Launch 2: its own entries stay, the crashed launch's file goes.
        let next = LocalStagingJournal(fileURL: journalURL, run: UUID())
        let own = folder.appending(path: FileNameRules.temporaryName(suffix: "download"))
        try Data("running".utf8).write(to: own)
        next.record(own)
        #expect(next.sweep() == 1)
        #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: own.path(percentEncoded: false)), "the running launch's download is untouched")
        #expect(FileManager.default.fileExists(atPath: userFile.path(percentEncoded: false)))
        #expect(next.entries.count == 1)
    }

    @Test func finishedDownloadsLeaveNoEntries() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fs = MockDeviceFileSystem()
        let journal = LocalStagingJournal(fileURL: journalURL)
        let manager = TransferManager(fileSystemProvider: { _ in fs }, volume: FakeVolume(available: nil),
                                      scratchDirectory: folder.appending(path: ".scratch"), localJournal: journal)
        let root = FileItemID.root(deviceID: fs.deviceID, storageID: MockDeviceFileSystem.internalStorageID)
        let download = try #require(try await fs.contents(of: root).first { $0.name == "Download" })
        manager.enqueue(.download(items: [DeviceItemRef(item: download, parentPath: [])], generation: fs.generation,
                                  destination: folder, deleteSourceAfter: false), destinationName: "test")
        await manager.waitUntilIdle()
        #expect(manager.jobs.first?.state == .completed)
        #expect(journal.entries.isEmpty)
        #expect(LocalStagingJournal(fileURL: journalURL).entries.isEmpty, "saved state is empty too")
    }
}
