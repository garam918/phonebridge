import Foundation
import Testing
@testable import PhoneBridge

/// W3: what an interrupted operation leaves on a device is cleaned up in the
/// next session, and unsaved Finder writes are offered back. Mock device only.
@MainActor
@Suite("Device leftover journal (W3)", .serialized)
final class DeviceLeftoverJournalTests {
    static let storage = FinderWriteTests.storage
    let device = FinderWriteTests.makeDevice()
    let directory: URL
    var journalURL: URL { directory.appending(path: "journal.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "PBJournal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var docs: FileItemID { FileItemID(deviceID: .demo, storageID: Self.storage, objectID: FinderWriteTests.docsID) }
    private func id(_ objectID: UInt32) -> FileItemID { FileItemID(deviceID: .demo, storageID: Self.storage, objectID: objectID) }

    private func names() -> [String] {
        device.children(of: FinderWriteTests.docsID, storageID: Self.storage).map(\.name).sorted()
    }

    /// A journal as the next app launch sees it.
    private func nextLaunch() -> DeviceLeftoverJournal {
        DeviceLeftoverJournal(fileURL: journalURL, run: UUID())
    }

    private func buffer(_ text: String, in folder: URL) throws -> (String, UInt64) {
        let name = "buf-\(UUID().uuidString)"
        try Data(text.utf8).write(to: folder.appending(path: name))
        return (name, UInt64(text.utf8.count))
    }

    // MARK: - Sweep rules

    @Test func stagingIsRemovedAndBackupsGoBackWhenTheirNameIsFree() async throws {
        let journal = DeviceLeftoverJournal(fileURL: journalURL)
        let staging = FileNameRules.temporaryName()
        _ = try await device.rename(id(FinderWriteTests.otherID), to: staging)
        journal.record(.staging, named: staging, in: docs, path: ["Documents"], generation: 1)
        let backup = FileNameRules.temporaryName(suffix: "deleted")
        _ = try await device.rename(id(FinderWriteTests.originalID), to: backup)
        journal.record(.backup, named: backup, in: docs, path: ["Documents"], originalName: "보고서.txt", generation: 1)

        // The same launch and session never sweeps its own work in progress.
        #expect(await journal.sweep(device) == .init())
        #expect(names().allSatisfy(FileNameRules.isTemporary))

        let report = await nextLaunch().sweep(device)
        #expect(report == .init(removed: 1, restored: 1, kept: 0))
        #expect(names() == ["보고서.txt"])
        #expect(device.nodes(named: "보고서.txt").first?.content == FinderWriteTests.original)
        #expect(nextLaunch().entries.isEmpty, "settled entries are gone from the saved journal")
    }

    @Test func backupIsRemovedWhenItsNameWasTakenMeanwhile() async throws {
        let backup = FileNameRules.temporaryName(suffix: "bak")
        _ = try await device.rename(id(FinderWriteTests.otherID), to: backup)
        DeviceLeftoverJournal(fileURL: journalURL).record(.backup, named: backup, in: docs, path: nil, originalName: "보고서.txt",
                                                         generation: 1)
        #expect(await nextLaunch().sweep(device) == .init(removed: 1, restored: 0, kept: 0))
        #expect(names() == ["보고서.txt"])
        #expect(device.nodes(named: "보고서.txt").first?.content == FinderWriteTests.original, "the newer file stays")
    }

    @Test func folderIsFoundByPathWhenHandlesChanged() async throws {
        let staging = FileNameRules.temporaryName()
        _ = try await device.rename(id(FinderWriteTests.otherID), to: staging)
        let staleHandle = FileItemID(deviceID: .demo, storageID: Self.storage, objectID: 0xBEEF)
        DeviceLeftoverJournal(fileURL: journalURL).record(.staging, named: staging, in: staleHandle, path: ["Documents"], generation: 1)
        #expect(await nextLaunch().sweep(device).removed == 1)
        #expect(names() == ["보고서.txt"])
    }

    @Test func onlyExactTemporaryNamesAreEverTouched() async throws {
        let journal = DeviceLeftoverJournal(fileURL: journalURL)
        journal.record(.staging, named: "보고서.txt", in: docs, path: nil, generation: 1)   // corrupted entry
        journal.record(.staging, named: FileNameRules.temporaryName(), in: docs, path: nil, generation: 1)   // never created
        #expect(await nextLaunch().sweep(device) == .init())
        #expect(names() == ["other.txt", "보고서.txt"])
        #expect(nextLaunch().entries.isEmpty)
    }

    @Test func entriesStayWhenTheDeviceIsGoneAgain() async throws {
        let staging = FileNameRules.temporaryName()
        _ = try await device.rename(id(FinderWriteTests.otherID), to: staging)
        DeviceLeftoverJournal(fileURL: journalURL).record(.staging, named: staging, in: docs, path: nil, generation: 1)
        device.simulateDisconnect()
        #expect(await nextLaunch().sweep(device).kept == 1)
        #expect(nextLaunch().entries.count == 1)
    }

    // MARK: - Crashes in the middle of Finder writes

    @Test func stagingThatCouldNotBeRemovedIsCleanedNextTime() async throws {
        let writes = FinderWriteCoordinator(bufferDirectory: directory, journal: DeviceLeftoverJournal(fileURL: journalURL))
        device.configureFaults {
            $0.chunkSize = 4
            $0.failAfterBytes = 8
            $0.leavePartialUploads = true
            $0.failing[.delete] = .timeout
        }
        let (name, size) = try buffer("0123456789abcdef", in: directory)
        await #expect(throws: FinderIPCError.self) {
            _ = try await writes.commit(CommitRequest(parent: FinderWriteTests.docsID, parentPath: ["Documents"], name: "새.txt",
                                                      replacing: nil, bufferName: name, size: size, modified: nil),
                                        in: self.docs, freeSpace: nil, fileSystem: self.device)
        }
        #expect(names().contains(where: FileNameRules.isTemporary), "partial staging object left behind")
        device.configureFaults { $0.failing = [:] }
        #expect(await nextLaunch().sweep(device).removed == 1)
        #expect(names() == ["other.txt", "보고서.txt"])
    }

    @Test func deleteInterruptedBeforeItsGracePeriodGivesTheFileBack() async throws {
        let writes = FinderWriteCoordinator(bufferDirectory: directory, deleteGrace: .seconds(60),
                                            journal: DeviceLeftoverJournal(fileURL: journalURL))
        try await writes.delete(id(FinderWriteTests.originalID), in: docs, path: ["Documents"], fileSystem: device)
        #expect(names().filter { !FileNameRules.isTemporary($0) } == ["other.txt"])
        // The app quits here without finishing the delayed delete.
        #expect(await nextLaunch().sweep(device).restored == 1)
        #expect(names() == ["other.txt", "보고서.txt"])
        #expect(device.nodes(named: "보고서.txt").first?.content == FinderWriteTests.original)
    }

    @Test func replacedFileStuckAsBackupIsRestored() async throws {
        let writes = FinderWriteCoordinator(bufferDirectory: directory, journal: DeviceLeftoverJournal(fileURL: journalURL))
        // rename 1: original → backup, 2: staging → final (fails), 3: backup → original (fails too).
        device.configureFaults { $0.failingFromCall[.rename] = (2, .timeout) }
        let (name, size) = try buffer("새 버전", in: directory)
        await #expect(throws: FinderIPCError.self) {
            _ = try await writes.commit(CommitRequest(parent: FinderWriteTests.docsID, name: "보고서.txt",
                                                      replacing: FinderWriteTests.originalID, bufferName: name, size: size, modified: nil),
                                        in: self.docs, freeSpace: nil, fileSystem: self.device)
        }
        #expect(!names().contains("보고서.txt"), "original stuck under its backup name")
        device.configureFaults { $0.failingFromCall = [:] }
        #expect(await nextLaunch().sweep(device).restored == 1)
        #expect(device.nodes(named: "보고서.txt").first?.content == FinderWriteTests.original)
        #expect(!names().contains(where: FileNameRules.isTemporary))
    }

    @Test func normalWritesLeaveNothingInTheJournal() async throws {
        let journal = DeviceLeftoverJournal(fileURL: journalURL)
        let writes = FinderWriteCoordinator(bufferDirectory: directory, deleteGrace: .milliseconds(50), journal: journal)
        let (name, size) = try buffer("새 버전", in: directory)
        _ = try await writes.commit(CommitRequest(parent: FinderWriteTests.docsID, name: "보고서.txt", replacing: FinderWriteTests.originalID,
                                                  bufferName: name, size: size, modified: nil),
                                    in: docs, freeSpace: nil, fileSystem: device)
        try await writes.delete(id(FinderWriteTests.otherID), in: docs, fileSystem: device)
        try await waitUntil { journal.entries.isEmpty }
        #expect(!names().contains(where: FileNameRules.isTemporary))
    }

    @Test func transferManagerUploadsAreJournaledToo() async throws {
        let journal = DeviceLeftoverJournal(fileURL: journalURL)
        let device = self.device
        let manager = TransferManager(fileSystemProvider: { _ in device }, scratchDirectory: directory.appending(path: "scratch"),
                                      journal: journal)
        manager.conflictResolver = { _ in ConflictDecision(action: .replace, applyToAll: true) }
        let source = directory.appending(path: "보고서.txt")
        try Data("앱에서 올린 새 버전".utf8).write(to: source)
        let job = manager.enqueue(.upload(sources: [source], destination: DeviceFolderRef(id: docs, path: ["Documents"]), generation: 1,
                                          removeSourceAfter: false), destinationName: "Documents")
        await manager.waitUntilIdle()
        #expect(job.state == .completed)
        #expect(journal.entries.isEmpty, "staging and backup entries are removed once settled")
        #expect(device.nodes(named: "보고서.txt").first?.content == Data("앱에서 올린 새 버전".utf8))
    }
}

// MARK: - Unsaved Finder writes

@MainActor
@Suite("Finder write recovery (W3)", .serialized)
final class FinderWriteRecoveryTests {
    let directory: URL
    let recovery: FinderWriteRecovery
    var locks: [Int32] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "PBRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        recovery = FinderWriteRecovery(directory: directory)
    }

    deinit {
        locks.forEach(WriteBufferLock.release)
        try? FileManager.default.removeItem(at: directory)
    }

    /// A buffer as the extension leaves it; `locked` = still mounted.
    @discardableResult
    private func buffer(_ text: String, name: String = FinderWritePolicy.newBufferName(), file: String? = "사진 메모.txt",
                        state: WriteBufferManifest.State = .writing, locked: Bool = false) throws -> String {
        let url = directory.appending(path: name)
        try Data(text.utf8).write(to: url)
        if let file {
            let manifest = WriteBufferManifest(bufferName: name, volume: VolumeAddress(deviceID: "demo", storageID: 1, generation: 1),
                                               volumeName: "가상 Android 기기 – 내부 저장공간", folderPath: ["Download"], fileName: file,
                                               state: state, updated: Date(), lastError: state == .failed ? "error.insufficientDeviceSpace" : nil)
            try JSONEncoder().encode(manifest).write(to: directory.appending(path: WriteBufferManifest.manifestName(for: name)))
        }
        if locked {
            let fd = WriteBufferLock.acquire(url)
            #expect(fd >= 0)
            locks.append(fd)
        }
        return name
    }

    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appending(path: name).path) }

    @Test func onlyBuffersNobodyUsesOrThatFailedAreOffered() throws {
        try buffer("in progress", locked: true)
        let failed = try buffer("failed but mounted", file: "실패.txt", state: .failed, locked: true)
        let orphan = try buffer("left by an unmount", file: "남은.txt")
        let unnamed = try buffer("no manifest", file: nil)
        let shadow = try buffer("bookkeeping", name: FinderWritePolicy.newBufferName(shadow: true), file: nil)
        let empty = try buffer("", file: nil)
        let dsStore = FinderWritePolicy.newBufferName()
        try Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31, 0, 0]).write(to: directory.appending(path: dsStore))
        try Data("{}".utf8).write(to: directory.appending(path: WriteBufferManifest.manifestName(for: "w-gone")))

        #expect(recovery.scan() == 3)
        let byID = Dictionary(uniqueKeysWithValues: recovery.files.map { ($0.id, $0) })
        #expect(Set(byID.keys) == [failed, orphan, unnamed])
        #expect(byID[failed]?.inUse == true && byID[failed]?.uploadFailed == true)
        #expect(byID[orphan]?.inUse == false && byID[orphan]?.fileName == "남은.txt" && byID[orphan]?.folderPath == ["Download"])
        #expect(byID[unnamed]?.fileName == nil)
        #expect(!exists(shadow) && !exists(empty) && !exists(dsStore), "bookkeeping and empty buffers are removed")
        #expect(!exists(WriteBufferManifest.manifestName(for: "w-gone")), "manifest without its buffer is removed")
        #expect(recovery.scan() == 0, "nothing new the second time")
    }

    @Test func savingCopiesTheBytesAndForgetsTheBuffer() async throws {
        let name = try buffer("되살린 내용")
        recovery.scan()
        let file = try #require(recovery.files.first)
        let destination = FileManager.default.temporaryDirectory.appending(path: "PBSaved-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        try "old".write(to: destination, atomically: true, encoding: .utf8)
        try await recovery.save(file, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "되살린 내용")
        #expect(!exists(name) && !exists(WriteBufferManifest.manifestName(for: name)))
        #expect(recovery.files.isEmpty)
    }

    @Test func failedSaveLeavesTheExistingMacFileAlone() async throws {
        let name = try buffer("되살린 내용")
        recovery.scan()
        let file = try #require(recovery.files.first)
        let destination = FileManager.default.temporaryDirectory.appending(path: "PBSaved-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        try "old".write(to: destination, atomically: true, encoding: .utf8)
        // The buffer disappears between the scan and the save (committed meanwhile).
        try FileManager.default.removeItem(at: directory.appending(path: name))
        await #expect(throws: (any Error).self) { try await self.recovery.save(file, to: destination) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "old", "audit 2026-10-23, M4")
    }

    @Test func buffersInUseCanBeSavedButNotDiscarded() async throws {
        let name = try buffer("still mounted", state: .failed, locked: true)
        recovery.scan()
        let file = try #require(recovery.files.first)
        recovery.discard(file)
        #expect(exists(name))
        let copy = FileManager.default.temporaryDirectory.appending(path: "PBCopy-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: copy) }
        try await recovery.save(file, to: copy)
        #expect(exists(name), "the volume still uses it")
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func discardRemovesBufferAndManifest() throws {
        let name = try buffer("버릴 내용")
        recovery.scan()
        recovery.discard(try #require(recovery.files.first))
        #expect(!exists(name) && !exists(WriteBufferManifest.manifestName(for: name)))
        #expect(recovery.files.isEmpty)
    }

    @Test func lockIsSeenAcrossOpenFiles() throws {
        let url = directory.appending(path: "w-lock")
        try Data("x".utf8).write(to: url)
        #expect(!WriteBufferLock.isHeld(url))
        let fd = WriteBufferLock.acquire(url)
        #expect(WriteBufferLock.isHeld(url))
        WriteBufferLock.release(fd)
        #expect(!WriteBufferLock.isHeld(url))
    }
}
