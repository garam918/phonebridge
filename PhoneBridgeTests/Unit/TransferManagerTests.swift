import Foundation
import Testing
@testable import PhoneBridge

/// Fixed free-space answer for the Mac side.
struct FakeVolume: LocalVolumeInspecting {
    var available: UInt64?
    func availableCapacity(for url: URL) -> UInt64? { available }
}

/// Transfer engine against the in-memory mock device. Real local files are
/// written inside the app container's tmp directory.
@MainActor
@Suite("TransferManager (mock device, real local files)", .serialized)
final class TransferManagerTests {
    let fs = MockDeviceFileSystem()
    let local: URL
    var conflictAnswers: [ConflictDecision] = []
    var conflictsAsked: [TransferConflict] = []
    private(set) var manager: TransferManager!

    init() throws {
        local = FileManager.default.temporaryDirectory.appending(path: "PBTransferTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        manager = makeManager()
    }

    deinit {
        let url = local
        // Restore permissions changed by tests before cleaning up.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    func makeManager(volume: FakeVolume = FakeVolume(available: nil), fileSystem: (any DeviceFileSystem)? = nil) -> TransferManager {
        let target = fileSystem ?? fs
        let manager = TransferManager(fileSystemProvider: { $0 == target.deviceID ? target : nil }, volume: volume,
                                      scratchDirectory: local.appending(path: ".scratch"))
        manager.conflictResolver = { [unowned self] conflict in
            self.conflictsAsked.append(conflict)
            return self.conflictAnswers.isEmpty ? .always(.skip) : self.conflictAnswers.removeFirst()
        }
        return manager
    }

    // MARK: Helpers

    let storage = MockDeviceFileSystem.internalStorageID

    func folderRef(_ path: [String], in fileSystem: MockDeviceFileSystem? = nil) async throws -> DeviceFolderRef {
        let target = fileSystem ?? fs
        var folder = FileItemID.root(deviceID: target.deviceID, storageID: storage)
        for name in path {
            folder = try #require(try await target.contents(of: folder).first { $0.name == name }).id
        }
        return DeviceFolderRef(id: folder, path: path)
    }

    func itemRef(_ path: [String], in fileSystem: MockDeviceFileSystem? = nil) async throws -> DeviceItemRef {
        let target = fileSystem ?? fs
        let parent = try await folderRef(Array(path.dropLast()), in: target)
        let item = try #require(try await target.contents(of: parent.id).first { $0.name == path.last })
        return DeviceItemRef(item: item, parentPath: Array(path.dropLast()))
    }

    func deviceNames(_ path: [String]) async throws -> [String] {
        try await fs.contents(of: try await folderRef(path).id).map(\.name).sorted()
    }

    func deviceData(_ path: [String]) async throws -> Data? {
        let ref = try await itemRef(path)
        return fs.node(ref.id.objectID)?.content
    }

    @discardableResult
    func makeLocalFile(_ name: String, in directory: URL? = nil, bytes: Int = 1_000, seed: UInt8 = 7) throws -> URL {
        let url = (directory ?? local).appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: Int($0) &* 31 &+ Int(seed)) })
        try data.write(to: url)
        return url
    }

    func localNames(_ directory: URL? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (directory ?? local).path).filter { $0 != ".scratch" }.sorted()
    }

    func run(_ request: TransferRequest) async -> TransferJob {
        let job = manager.enqueue(request, destinationName: "test")
        await manager.waitUntilIdle()
        return job
    }

    func download(_ paths: [[String]], to destination: URL? = nil, deleteSource: Bool = false) async throws -> TransferJob {
        var refs: [DeviceItemRef] = []
        for path in paths { refs.append(try await itemRef(path)) }
        return await run(.download(items: refs, generation: fs.generation, destination: destination ?? local, deleteSourceAfter: deleteSource))
    }

    func upload(_ urls: [URL], to path: [String], removeSource: Bool = false) async throws -> TransferJob {
        await run(.upload(sources: urls, destination: try await folderRef(path), generation: fs.generation, removeSourceAfter: removeSource))
    }

    func noStagingLeftovers() async throws -> Bool {
        var pending = [FileItemID.root(deviceID: fs.deviceID, storageID: storage)]
        while let folder = pending.popLast() {
            for child in try await fs.contents(of: folder) {
                if FileNameRules.isTemporary(child.name) { return false }
                if child.isFolder { pending.append(child.id) }
            }
        }
        let enumerator = FileManager.default.enumerator(atPath: local.path)
        while let path = enumerator?.nextObject() as? String {
            if (path as NSString).lastPathComponent.hasPrefix(FileNameRules.temporaryPrefix) { return false }
        }
        return true
    }

    // MARK: - Small / folder / many

    @Test func smallFileDownloadIsVerifiedAndDated() async throws {
        let job = try await download([["Documents", "메모.txt"]])
        #expect(job.state == .completed)
        let url = local.appending(path: "메모.txt")
        let data = try Data(contentsOf: url)
        #expect(data.count == 2_048)
        #expect(data == MockDeviceFileSystem.pattern(objectID: try await itemRef(["Documents", "메모.txt"]).id.objectID, offset: 0, count: 2_048))
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        #expect(abs(modified.timeIntervalSince(try await itemRef(["Documents", "메모.txt"]).modified!)) < 1)
        #expect(job.finishedFiles == 1 && job.totalBytes == 2_048 && job.transferredBytes == 2_048)
        #expect(try await noStagingLeftovers())
    }

    @Test func folderDownloadKeepsStructureAndEmptyFolders() async throws {
        let job = try await download([["Documents"]])
        #expect(job.state == .completed)
        #expect(try localNames(local.appending(path: "Documents")) == ["가계부 2026.xlsx", "메모.txt", "빈 폴더"])
        #expect(try localNames(local.appending(path: "Documents/빈 폴더")).isEmpty)
        #expect(job.totalFiles == 2)
    }

    @Test func uploadsHangulEnglishAndEmojiNames() async throws {
        let names = ["한글 문서.txt", "English Report.pdf", "여행 🏝️ 사진.jpg", "😀.txt", "가족👨‍👩‍👧 앨범.heic"]
        let urls = try names.enumerated().map { try makeLocalFile($1, bytes: 500 + $0, seed: UInt8($0)) }
        let job = try await upload(urls, to: ["Download"])
        #expect(job.state == .completed)
        let deviceList = try await deviceNames(["Download"])
        for (index, name) in names.enumerated() {
            #expect(deviceList.contains(name), "\(name)")
            #expect(try await deviceData(["Download", name]) == (try Data(contentsOf: urls[index])))
        }
        #expect(try await noStagingLeftovers())

        // And back again: download into a fresh folder keeps the exact names.
        let back = local.appending(path: "back", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        let downloaded = try await download(names.map { ["Download", $0] }, to: back)
        #expect(downloaded.state == .completed)
        #expect(try localNames(back) == names.sorted())
    }

    @Test func folderUploadWithNestedAndEmptyFolders() async throws {
        let root = local.appending(path: "Trip", directoryHint: .isDirectory)
        try makeLocalFile("day1/photo.jpg", in: root, bytes: 3_000)
        try makeLocalFile("day1/notes/메모.txt", in: root, bytes: 120)
        try FileManager.default.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        try "x".write(to: root.appending(path: ".DS_Store"), atomically: true, encoding: .utf8)

        let job = try await upload([root], to: [])
        #expect(job.state == .completed)
        #expect(try await deviceNames(["Trip"]) == ["day1", "empty"])
        #expect(try await deviceNames(["Trip", "day1"]) == ["notes", "photo.jpg"])
        #expect(try await deviceNames(["Trip", "day1", "notes"]) == ["메모.txt"])
        #expect(try await deviceNames(["Trip", "empty"]).isEmpty)
        #expect(job.totalFiles == 2 && job.finishedFiles == 2)
    }

    @Test func manyFilesRoundTrip() async throws {
        let folder = local.appending(path: "bulk", directoryHint: .isDirectory)
        for index in 0..<200 {
            try makeLocalFile(String(format: "file-%03d.bin", index), in: folder, bytes: 256 + index, seed: UInt8(index % 251))
        }
        let up = try await upload([folder], to: [])
        #expect(up.state == .completed)
        #expect(up.totalFiles == 200 && up.finishedFiles == 200)
        #expect(try await deviceNames(["bulk"]).count == 200)

        let target = local.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let down = try await download([["bulk"]], to: target)
        #expect(down.state == .completed)
        for index in [0, 57, 199] {
            let name = String(format: "file-%03d.bin", index)
            #expect(try Data(contentsOf: target.appending(path: "bulk/\(name)")) == Data(contentsOf: folder.appending(path: name)))
        }
    }

    // MARK: - Large files

    @Test(.timeLimit(.minutes(3)))
    func uploadLargerThanFourGiBStreamsWithoutBuffering() async throws {
        fs.configureFaults {
            $0.storeUploadedContent = false
            $0.chunkSize = 16 << 20
        }
        let size: UInt64 = 4_500 * 1024 * 1024 // > UInt32.max: needs 64-bit sizes end to end
        let url = local.appending(path: "huge.mkv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size) // sparse: no real disk usage
        try handle.close()

        let job = try await upload([url], to: ["Download"])
        #expect(job.state == .completed)
        #expect(job.totalBytes == size)
        let uploaded = try await itemRef(["Download", "huge.mkv"])
        #expect(uploaded.size == size)
        #expect(try await noStagingLeftovers())
    }

    @Test(.timeLimit(.minutes(2)))
    func largeDownloadIsStreamedAndVerified() async throws {
        let size: UInt64 = 300 * 1024 * 1024
        let big = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree() + [
            .init(objectID: 0x9000, storageID: storage, parentID: FileItemID.rootObjectID, name: "movie.mp4",
                  isFolder: false, size: size, modified: Date()),
        ], faults: .init(chunkSize: 8 << 20))
        manager = makeManager(fileSystem: big)
        let ref = try await itemRef(["movie.mp4"], in: big)
        let job = await run(.download(items: [ref], generation: big.generation, destination: local, deleteSourceAfter: false))
        #expect(job.state == .completed)
        #expect(LocalFileIO.fileSize(local.appending(path: "movie.mp4")) == size)
    }

    // MARK: - Duplicates / repeats

    @Test func repeatedDownloadAsksAndKeepsBoth() async throws {
        _ = try await download([["Documents", "메모.txt"]])
        conflictAnswers = [ConflictDecision(action: .keepBoth, applyToAll: false)]
        let second = try await download([["Documents", "메모.txt"]])
        conflictAnswers = [ConflictDecision(action: .keepBoth, applyToAll: false)]
        _ = try await download([["Documents", "메모.txt"]])
        #expect(second.state == .completed)
        #expect(conflictsAsked.count == 2)
        #expect(conflictsAsked.first?.name == "메모.txt" && conflictsAsked.first?.canReplace == true)
        #expect(try localNames() == ["메모 2.txt", "메모 3.txt", "메모.txt"])
    }

    @Test func downloadReplaceSwapsAtomicallyAndSkipLeavesOriginal() async throws {
        let existing = try makeLocalFile("메모.txt", bytes: 10, seed: 99)
        let original = try Data(contentsOf: existing)

        conflictAnswers = [ConflictDecision(action: .skip, applyToAll: false)]
        let skipped = try await download([["Documents", "메모.txt"]])
        #expect(skipped.state == .completed && skipped.skippedFiles == 1)
        #expect(try Data(contentsOf: existing) == original)

        conflictAnswers = [ConflictDecision(action: .replace, applyToAll: false)]
        let replaced = try await download([["Documents", "메모.txt"]])
        #expect(replaced.state == .completed)
        #expect(try Data(contentsOf: existing).count == 2_048)
        #expect(try localNames() == ["메모.txt"])
    }

    @Test func repeatedUploadKeepsBothThenReplaceKeepsSingleCopy() async throws {
        let url = try makeLocalFile("report.pdf", bytes: 4_000)
        _ = try await upload([url], to: ["Download"])
        conflictAnswers = [.always(.keepBoth)]
        _ = try await upload([url], to: ["Download"])
        conflictAnswers = [.always(.keepBoth)]
        _ = try await upload([url], to: ["Download"])
        #expect(try await deviceNames(["Download"]).filter { $0.hasPrefix("report") } == ["report 2.pdf", "report 3.pdf", "report.pdf"])

        let changed = try makeLocalFile("report.pdf", bytes: 6_000, seed: 3)
        conflictAnswers = [ConflictDecision(action: .replace, applyToAll: false)]
        let job = try await upload([changed], to: ["Download"])
        #expect(job.state == .completed)
        #expect(try await deviceData(["Download", "report.pdf"]) == (try Data(contentsOf: changed)))
        #expect(fs.nodes(named: "report.pdf").count == 1)
        #expect(try await noStagingLeftovers(), "backup of the replaced file must be removed")
    }

    @Test func twoMacNamesThatBecomeOneDeviceNameAreBothKept() async throws {
        // ":" and "?" both become "_" on the device; "Replace all" must not let
        // the second upload replace the first one from the same job.
        let first = try makeLocalFile("a:b.txt", bytes: 1_000, seed: 1)
        let second = try makeLocalFile("a?b.txt", bytes: 2_000, seed: 2)
        conflictAnswers = [.always(.replace)]
        let job = try await upload([first, second], to: ["Download"])
        #expect(job.state == .completed)
        #expect(conflictsAsked.isEmpty, "a clash with this job's own upload is not a question")
        #expect(try await deviceNames(["Download"]).filter { $0.hasPrefix("a_b") } == ["a_b 2.txt", "a_b.txt"])
        #expect(try await deviceData(["Download", "a_b.txt"]) == (try Data(contentsOf: first)))
        #expect(try await deviceData(["Download", "a_b 2.txt"]) == (try Data(contentsOf: second)))
    }

    @Test func applyToAllAsksOnceForFolderMerge() async throws {
        let folder = local.appending(path: "Music", directoryHint: .isDirectory)
        try makeLocalFile("봄날.mp3", in: folder, bytes: 100)
        try makeLocalFile("new.mp3", in: folder, bytes: 100)
        try makeLocalFile("Recording 001.m4a", in: folder, bytes: 100)
        // Folder conflict → merge, then two file conflicts answered by "apply to all".
        conflictAnswers = [ConflictDecision(action: .replace, applyToAll: false), ConflictDecision(action: .keepBoth, applyToAll: true)]
        let job = try await upload([folder], to: [])
        #expect(job.state == .completed)
        #expect(conflictsAsked.count == 2)
        #expect(conflictsAsked[0].isFolder)
        #expect(try await deviceNames(["Music"]) == ["Recording 001 2.m4a", "Recording 001.m4a", "new.mp3", "봄날 2.mp3", "봄날.mp3"])
    }

    @Test func replaceIsDowngradedWhenDeviceCannotRename() async throws {
        let noRename = MockDeviceFileSystem(capabilities: FileSystemCapabilities(canWrite: true, canRename: false,
                                                                                 canMoveNatively: false, canCopyNatively: false, canThumbnail: false))
        manager = makeManager(fileSystem: noRename)
        let url = try makeLocalFile("메모.txt", bytes: 10)
        conflictAnswers = [.always(.replace)]
        let job = await run(.upload(sources: [url], destination: try await folderRef(["Documents"], in: noRename),
                                    generation: 1, removeSourceAfter: false))
        #expect(job.state == .completed)
        #expect(conflictsAsked.first?.canReplace == false)
        let names = try await noRename.contents(of: try await folderRef(["Documents"], in: noRename).id).map(\.name)
        #expect(names.contains("메모.txt") && names.contains("메모 2.txt"), "original must survive")
    }

    // MARK: - Cancel / unplug

    @Test func cancelDuringDownloadRemovesStagingFile() async throws {
        let slow = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree() + [
            .init(objectID: 0x9001, storageID: storage, parentID: FileItemID.rootObjectID, name: "big.bin",
                  isFolder: false, size: 64 << 20, modified: nil),
        ], faults: .init(chunkSize: 256 << 10, chunkDelay: .milliseconds(2)))
        manager = makeManager(fileSystem: slow)
        let job = manager.enqueue(.download(items: [try await itemRef(["big.bin"], in: slow)], generation: 1,
                                            destination: local, deleteSourceAfter: false), destinationName: "t")
        try await waitUntil { job.currentBytes > 0 }
        manager.cancel(job)
        await manager.waitUntilIdle()
        #expect(job.state == .cancelled)
        #expect(job.canRetry)
        #expect(try localNames().isEmpty, "no partial or staging file may remain")
    }

    @Test func cancelDuringUploadLeavesNothingOnDevice() async throws {
        fs.configureFaults {
            $0.chunkSize = 64 << 10
            $0.chunkDelay = .milliseconds(2)
            $0.leavePartialUploads = true
        }
        let url = try makeLocalFile("video.mov", bytes: 32 << 20)
        let job = manager.enqueue(.upload(sources: [url], destination: try await folderRef(["Download"]), generation: 1,
                                          removeSourceAfter: false), destinationName: "t")
        try await waitUntil { job.currentBytes > 0 }
        manager.cancel(job)
        await manager.waitUntilIdle()
        #expect(job.state == .cancelled)
        #expect(!(try await deviceNames(["Download"])).contains("video.mov"))
        #expect(try await noStagingLeftovers(), "partial staging object must be cleaned up")
        #expect(FileManager.default.fileExists(atPath: url.path), "source untouched")
    }

    @Test func unplugDuringDownloadFailsCleanly() async throws {
        let slow = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree() + [
            .init(objectID: 0x9002, storageID: storage, parentID: FileItemID.rootObjectID, name: "big.bin",
                  isFolder: false, size: 64 << 20, modified: nil),
        ], faults: .init(chunkSize: 256 << 10, chunkDelay: .milliseconds(2)))
        manager = makeManager(fileSystem: slow)
        let job = manager.enqueue(.download(items: [try await itemRef(["big.bin"], in: slow)], generation: 1,
                                            destination: local, deleteSourceAfter: false), destinationName: "t")
        try await waitUntil { job.currentBytes > 0 }
        slow.simulateDisconnect()
        await manager.waitUntilIdle()
        #expect(job.state == .failed(.disconnected))
        #expect(job.canRetry)
        #expect(try localNames().isEmpty)
    }

    @Test func midTransferFailureOfUploadRemovesPartialObject() async throws {
        fs.configureFaults {
            $0.chunkSize = 1 << 10
            $0.failAfterBytes = 4 << 10
            $0.transferFailure = .usbError(code: -1, detail: "pipe")
            $0.leavePartialUploads = true
        }
        let url = try makeLocalFile("doc.pdf", bytes: 20 << 10)
        let job = try await upload([url], to: ["Download"])
        #expect(job.state == .failed(.usbError(code: -1, detail: "pipe")))
        #expect(try await noStagingLeftovers())
        #expect(!(try await deviceNames(["Download"])).contains("doc.pdf"))
    }

    // MARK: - Space / permissions / verification / capabilities

    @Test func insufficientMacSpaceFailsBeforeTransfer() async throws {
        manager = makeManager(volume: FakeVolume(available: 1_000_000))
        let job = try await download([["DCIM", "Camera"]])
        guard case .failed(.insufficientLocalSpace(let required, let available)) = job.state else {
            Issue.record("expected insufficientLocalSpace, got \(job.state)")
            return
        }
        #expect(required > 30_000_000 && available == 1_000_000)
        #expect(try localNames().isEmpty)
        #expect(!fs.operationLog.contains(.download))
    }

    @Test func insufficientDeviceSpaceFailsBeforeTransfer() async throws {
        fs.setFreeSpace(1_000, storageID: storage)
        let url = try makeLocalFile("big.zip", bytes: 50_000)
        let job = try await upload([url], to: ["Download"])
        #expect(job.state == .failed(.insufficientDeviceSpace(required: 50_000, available: 1_000)))
        #expect(!fs.operationLog.contains(.upload))
    }

    @Test func deviceRunningOutOfSpaceMidTransferIsReported() async throws {
        fs.configureFaults {
            $0.chunkSize = 1 << 10
            $0.failAfterBytes = 2 << 10
            $0.transferFailure = .storageFull
        }
        let job = try await upload([try makeLocalFile("a.bin", bytes: 10 << 10)], to: ["Download"])
        #expect(job.state == .failed(.storageFull))
        #expect(try await noStagingLeftovers())
    }

    @Test func unwritableMacFolderIsReportedAsPermissionError() async throws {
        let locked = local.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let job = try await download([["Documents", "메모.txt"]], to: locked)
        #expect(job.state == .failed(.localPermissionDenied(path: locked.path(percentEncoded: false))))
    }

    @Test func unreadableMacFileFailsBeforeUploading() async throws {
        let secret = try makeLocalFile("secret.txt", bytes: 100)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }
        let job = try await upload([secret], to: ["Download"])
        #expect(job.state == .failed(.localPermissionDenied(path: secret.path(percentEncoded: false))))
        #expect(!fs.operationLog.contains(.upload))
    }

    @Test func readOnlyStorageRejectsWrites() async throws {
        let readOnly = MockDeviceFileSystem(storages: [StorageInfo(id: storage, name: "ROM", capacity: 1_000_000, freeSpace: 500_000,
                                                                   kind: .internalStorage, isReadOnly: true)])
        manager = makeManager(fileSystem: readOnly)
        let job = await run(.upload(sources: [try makeLocalFile("a.txt")], destination: try await folderRef(["Download"], in: readOnly),
                                    generation: 1, removeSourceAfter: false))
        #expect(job.state == .failed(.readOnlyStorage))
        #expect(!job.canRetry)
    }

    @Test func uploadVerificationFailureRemovesTheBadCopy() async throws {
        fs.configureFaults { $0.corruptUploads = true }
        let job = try await upload([try makeLocalFile("photo.jpg", bytes: 10_000)], to: ["Download"])
        #expect(job.state == .failed(.verificationFailed(expected: 10_000, actual: 5_000)))
        #expect(!(try await deviceNames(["Download"])).contains("photo.jpg"))
        #expect(try await noStagingLeftovers())
    }

    @Test func downloadVerificationFailureLeavesNoFile() async throws {
        let short = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree() + [
            .init(objectID: 0x9003, storageID: storage, parentID: FileItemID.rootObjectID, name: "short.bin",
                  isFolder: false, size: 100, modified: nil, content: Data(repeating: 1, count: 60)),
        ])
        manager = makeManager(fileSystem: short)
        let job = await run(.download(items: [try await itemRef(["short.bin"], in: short)], generation: 1,
                                      destination: local, deleteSourceAfter: false))
        #expect(job.state == .failed(.verificationFailed(expected: 100, actual: 60)))
        #expect(try localNames().isEmpty)
    }

    @Test func failedReplaceKeepsTheOriginal() async throws {
        let url = try makeLocalFile("메모.txt", bytes: 77)
        let before = try await itemRef(["Documents", "메모.txt"])
        fs.configureFaults { $0.failing[.rename] = .protocolError(code: 0x2002, detail: "mock rename failure") }
        conflictAnswers = [.always(.replace)]
        let job = try await upload([url], to: ["Documents"])
        #expect(job.state == .failed(.protocolError(code: 0x2002, detail: "mock rename failure")))
        let after = try await itemRef(["Documents", "메모.txt"])
        #expect(after.id == before.id && after.size == 2_048, "original object must be untouched")
        #expect(try await noStagingLeftovers())
    }

    @Test func readOnlyDeviceCapabilitiesDisableWrites() async throws {
        let readOnly = MockDeviceFileSystem(capabilities: .readOnly)
        manager = makeManager(fileSystem: readOnly)
        let job = await run(.upload(sources: [try makeLocalFile("a.txt")], destination: try await folderRef([], in: readOnly),
                                    generation: 1, removeSourceAfter: false))
        #expect(job.state == .failed(.unsupportedOperation))
    }

    // MARK: - Copy / move / delete

    @Test func nativeCopyAndMoveOnDevice() async throws {
        let copyJob = await run(.deviceCopy(items: [try await itemRef(["Documents", "메모.txt"])],
                                            destination: try await folderRef(["Download"]), generation: 1, move: false))
        #expect(copyJob.state == .completed)
        #expect(try await deviceNames(["Download"]).contains("메모.txt"))
        #expect(try await deviceNames(["Documents"]).contains("메모.txt"))

        let moveJob = await run(.deviceCopy(items: [try await itemRef(["Pictures", "KakaoTalk"])],
                                            destination: try await folderRef(["DCIM"]), generation: 1, move: true))
        #expect(moveJob.state == .completed)
        #expect(try await deviceNames(["DCIM", "KakaoTalk"]) == ["가족사진.jpg", "여행_제주.heic"])
        #expect(!(try await deviceNames(["Pictures"])).contains("KakaoTalk"))
    }

    @Test func copyIntoSameFolderMakesNumberedDuplicate() async throws {
        let job = await run(.deviceCopy(items: [try await itemRef(["Documents", "메모.txt"])],
                                        destination: try await folderRef(["Documents"]), generation: 1, move: false))
        #expect(job.state == .completed)
        #expect(try await deviceNames(["Documents"]).contains("메모 2.txt"))
    }

    @Test func movingFolderIntoItselfIsRejected() async throws {
        let job = await run(.deviceCopy(items: [try await itemRef(["DCIM"])],
                                        destination: try await folderRef(["DCIM", "Camera"]), generation: 1, move: true))
        #expect(job.state == .failed(.invalidDestination))
        #expect(try await deviceNames([]).contains("DCIM"))
    }

    @Test func copyAndMoveFallBackThroughMacWhenUnsupported() async throws {
        let basic = MockDeviceFileSystem(capabilities: FileSystemCapabilities(canWrite: true, canRename: true, canMoveNatively: false,
                                                                              canCopyNatively: false, canThumbnail: false))
        manager = makeManager(fileSystem: basic)
        let copy = await run(.deviceCopy(items: [try await itemRef(["Documents"], in: basic)],
                                         destination: try await folderRef(["Download"], in: basic), generation: 1, move: false))
        #expect(copy.state == .completed)
        let copied = try await basic.contents(of: try await folderRef(["Download", "Documents"], in: basic).id).map(\.name).sorted()
        #expect(copied == ["가계부 2026.xlsx", "메모.txt", "빈 폴더"])

        let move = await run(.deviceCopy(items: [try await itemRef(["Music", "봄날.mp3"], in: basic)],
                                         destination: try await folderRef(["Download"], in: basic), generation: 1, move: true))
        #expect(move.state == .completed)
        #expect(try await basic.contents(of: try await folderRef(["Music"], in: basic).id).map(\.name) == ["Recording 001.m4a"])
        #expect(try await basic.contents(of: try await folderRef(["Download"], in: basic).id).contains { $0.name == "봄날.mp3" && $0.size == 8_812_004 })
        #expect(try localNames().isEmpty, "scratch copies are removed")
    }

    @Test func deleteRemovesWholeTreeBottomUp() async throws {
        let job = await run(.delete(items: [try await itemRef(["DCIM"]), try await itemRef(["Music", "봄날.mp3"])], generation: 1))
        #expect(job.state == .completed)
        #expect(job.totalFiles == 19 && job.finishedFiles == 19)
        #expect(!(try await deviceNames([])).contains("DCIM"))
        #expect(try await deviceNames(["Music"]) == ["Recording 001.m4a"])
    }

    @Test func moveFromDeviceToMacDeletesSourceOnlyAfterSuccess() async throws {
        let job = try await download([["Pictures", "KakaoTalk"]], deleteSource: true)
        #expect(job.state == .completed)
        #expect(try localNames(local.appending(path: "KakaoTalk")) == ["가족사진.jpg", "여행_제주.heic"])
        #expect(!(try await deviceNames(["Pictures"])).contains("KakaoTalk"))
    }

    @Test func queueRunsJobsInOrderAndReportsOverallProgress() async throws {
        let first = manager.enqueue(.download(items: [try await itemRef(["Documents", "메모.txt"])], generation: 1,
                                              destination: local, deleteSourceAfter: false), destinationName: "a")
        let second = manager.enqueue(.download(items: [try await itemRef(["Music", "봄날.mp3"])], generation: 1,
                                               destination: local, deleteSourceAfter: false), destinationName: "b")
        #expect(manager.activeJobs.count == 2)
        await manager.waitUntilIdle()
        #expect(first.state == .completed && second.state == .completed)
        #expect(manager.activeJobs.isEmpty && manager.overallFraction == nil)
        manager.clearFinished()
        #expect(manager.jobs.isEmpty)
    }

    @Test func retryRunsTheSameRequestAgain() async throws {
        fs.configureFaults { $0.failing[.download] = .timeout }
        let job = try await download([["Documents", "메모.txt"]])
        #expect(job.state == .failed(.timeout))
        fs.configureFaults { $0.failing[.download] = nil }
        let retried = try #require(manager.retry(job))
        await manager.waitUntilIdle()
        #expect(retried.state == .completed)
        #expect(!manager.jobs.contains { $0 === job })
    }

    // MARK: - Moves never delete what was not copied (audit 2026-10-23, H1/H5/H6)

    func newPhoto(in folder: UInt32, objectID: UInt32 = 0x9000) -> MockDeviceFileSystem.Node {
        MockDeviceFileSystem.Node(objectID: objectID, storageID: storage, parentID: folder, name: "새 사진.jpg",
                                  isFolder: false, size: 4_000, modified: Date())
    }

    @Test func movedFolderIsRemovedWhenEverythingWasCopied() async throws {
        fs.configureFaults { $0.deletesFoldersRecursively = true }
        let job = try await download([["Pictures", "KakaoTalk"]], deleteSource: true)
        #expect(job.state == .completed && job.keptFolders.isEmpty)
        #expect(!(try await deviceNames(["Pictures"])).contains("KakaoTalk"))
    }

    @Test func moveToMacKeepsFilesAddedDuringTheTransfer() async throws {
        let folder = try await itemRef(["Pictures", "KakaoTalk"])
        let added = newPhoto(in: folder.id.objectID)
        // Android deletes folders recursively; the camera writes while we copy.
        fs.configureFaults {
            $0.deletesFoldersRecursively = true
            $0.nodesAddedAfterDownload = [added]
        }
        let job = try await download([["Pictures", "KakaoTalk"]], deleteSource: true)
        #expect(job.state == .completed)
        #expect(try localNames(local.appending(path: "KakaoTalk")) == ["가족사진.jpg", "여행_제주.heic"])
        #expect(fs.node(added.objectID) != nil, "the new photo was never copied, so it must stay")
        #expect(try await deviceNames(["Pictures", "KakaoTalk"]) == ["새 사진.jpg"], "copied files are removed")
        #expect(job.keptFolders == ["KakaoTalk"])
    }

    @Test func moveToMacKeepsObjectsTheListingLeftOut() async throws {
        let unreadable = try await itemRef(["Pictures", "KakaoTalk", "가족사진.jpg"])
        // libmtp skips children whose metadata it cannot read, without an error.
        fs.configureFaults {
            $0.deletesFoldersRecursively = true
            $0.unlistedObjects = [unreadable.id.objectID]
        }
        let job = try await download([["Pictures", "KakaoTalk"]], deleteSource: true)
        #expect(job.state == .completed)
        #expect(try localNames(local.appending(path: "KakaoTalk")) == ["여행_제주.heic"])
        #expect(fs.node(unreadable.id.objectID) != nil, "an object we could not list was not copied and must survive")
        #expect(job.keptFolders == ["KakaoTalk"])
    }

    @Test func deviceMoveThroughMacKeepsFilesAddedDuringTheCopy() async throws {
        let basic = MockDeviceFileSystem(capabilities: FileSystemCapabilities(canWrite: true, canRename: true, canMoveNatively: false,
                                                                              canCopyNatively: false, canThumbnail: false))
        manager = makeManager(fileSystem: basic)
        let source = try await itemRef(["Pictures", "KakaoTalk"], in: basic)
        let added = newPhoto(in: source.id.objectID)
        basic.configureFaults {
            $0.deletesFoldersRecursively = true
            $0.nodesAddedAfterDownload = [added]
        }
        let job = await run(.deviceCopy(items: [source], destination: try await folderRef(["Download"], in: basic),
                                        generation: 1, move: true))
        #expect(job.state == .completed)
        let moved = try await basic.contents(of: try await folderRef(["Download", "KakaoTalk"], in: basic).id).map(\.name).sorted()
        #expect(moved == ["가족사진.jpg", "여행_제주.heic"])
        #expect(basic.node(added.objectID) != nil)
        #expect(job.keptFolders == ["KakaoTalk"])
    }

    @Test func oneJobNeverReplacesItsOwnOutput() async throws {
        let first = Data(repeating: 1, count: 300)
        let second = Data(repeating: 2, count: 500)
        let root = FileItemID.rootObjectID
        let device = MockDeviceFileSystem(nodes: [
            .init(objectID: 0x10, storageID: storage, parentID: root, name: "Camera", isFolder: true),
            .init(objectID: 0x11, storageID: storage, parentID: 0x10, name: "IMG_0001.JPG", isFolder: false,
                  size: UInt64(first.count), content: first),
            .init(objectID: 0x20, storageID: storage, parentID: root, name: "Edited", isFolder: true),
            // Same name in another folder (a recursive search result), differing only in case.
            .init(objectID: 0x21, storageID: storage, parentID: 0x20, name: "img_0001.jpg", isFolder: false,
                  size: UInt64(second.count), content: second),
        ])
        device.configureFaults { $0.deletesFoldersRecursively = true }
        manager = makeManager(fileSystem: device)
        // A genuine conflict with an older Mac file, answered "replace all".
        try makeLocalFile("IMG_0001.JPG", bytes: 10, seed: 99)
        conflictAnswers = [.always(.replace)]

        let job = await run(.download(items: [try await itemRef(["Camera", "IMG_0001.JPG"], in: device),
                                              try await itemRef(["Edited", "img_0001.jpg"], in: device)],
                                      generation: 1, destination: local, deleteSourceAfter: true))
        #expect(job.state == .completed)
        #expect(conflictsAsked.count == 1, "only the older Mac file is a conflict")
        let saved = try localNames().map { try Data(contentsOf: local.appending(path: $0)) }
        #expect(Set(saved) == [first, second], "both moved files exist on the Mac")
        #expect(device.node(0x11) == nil && device.node(0x21) == nil)
    }

    @Test func deviceReplaceKeepsAJournaledBackupWhenItCannotRestore() async throws {
        let memo = try await itemRef(["Documents", "메모.txt"])
        let download = try await folderRef(["Download"])
        _ = await run(.deviceCopy(items: [memo], destination: download, generation: 1, move: false))
        // Second copy replaces it: rename 1 sets the old copy aside, the copy
        // fails (unplug), and rename 2 (restore) fails too.
        fs.configureFaults {
            $0.failing[.copy] = .disconnected
            $0.failingCall[.rename] = (call: 2, error: .disconnected)
        }
        conflictAnswers = [.always(.replace)]
        let job = await run(.deviceCopy(items: [memo], destination: download, generation: 1, move: false))
        #expect(job.state == .failed(.disconnected))
        let backup = try #require(manager.journal.entries.first)
        #expect(manager.journal.entries.count == 1)
        #expect(backup.kind == .backup && backup.originalName == "메모.txt" && backup.folderPath == ["Download"],
                "the next session's sweep can restore it")
        #expect(job.warnings == [backup.name])
        #expect(fs.nodes(named: backup.name).count == 1)
    }

    // MARK: - Cancel before a question (audit 2026-10-23, M2)

    @Test func cancelledJobNeverOpensAConflictQuestion() async throws {
        let root = FileItemID.rootObjectID
        let content = Data("memo".utf8)
        let device = MockDeviceFileSystem(latency: .milliseconds(300), nodes: [
            .init(objectID: 0x10, storageID: storage, parentID: root, name: "Documents", isFolder: true),
            .init(objectID: 0x11, storageID: storage, parentID: 0x10, name: "메모.txt", isFolder: false, size: 4, content: content),
            .init(objectID: 0x20, storageID: storage, parentID: root, name: "Download", isFolder: true),
            .init(objectID: 0x21, storageID: storage, parentID: 0x20, name: "메모.txt", isFolder: false, size: 4, content: content),
        ])
        manager = makeManager(fileSystem: device)
        manager.conflictResolver = nil // the app's path: the question waits for the user
        let job = manager.enqueue(.deviceCopy(items: [try await itemRef(["Documents", "메모.txt"], in: device)],
                                              destination: try await folderRef(["Download"], in: device), generation: 1, move: false),
                                  destinationName: "test")
        try await waitUntil { job.state == .running }
        manager.cancel(job) // while it lists the destination, before the clash is known
        try await waitUntil(timeout: .seconds(3)) { job.state.isFinished }
        #expect(job.state == .cancelled)
        #expect(manager.pendingConflict == nil, "quitting would otherwise wait for an answer forever")
    }

    // MARK: - Device names never leave the chosen Mac folder (audit 2026-10-23, H4)

    @Test func hostileDeviceNamesStayInsideTheDestination() async throws {
        let root = FileItemID.rootObjectID
        let content = Data("x".utf8)
        // Names a malicious or broken MTP responder could report.
        let device = MockDeviceFileSystem(nodes: [
            .init(objectID: 0x10, storageID: storage, parentID: root, name: "Hostile", isFolder: true),
            .init(objectID: 0x11, storageID: storage, parentID: 0x10, name: "../../escape.txt", isFolder: false,
                  size: 1, content: content),
            .init(objectID: 0x12, storageID: storage, parentID: 0x10, name: "..", isFolder: true),
            .init(objectID: 0x13, storageID: storage, parentID: 0x12, name: "merged.txt", isFolder: false, size: 1, content: content),
            .init(objectID: 0x14, storageID: storage, parentID: 0x10, name: "a/b.txt", isFolder: false, size: 1, content: content),
            .init(objectID: 0x20, storageID: storage, parentID: root, name: "../top.txt", isFolder: false, size: 1, content: content),
        ])
        manager = makeManager(fileSystem: device)
        let destination = local.appending(path: "dest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let job = await run(.download(items: [try await itemRef(["Hostile"], in: device), try await itemRef(["../top.txt"], in: device)],
                                      generation: 1, destination: destination, deleteSourceAfter: false))
        #expect(job.state == .completed)
        #expect(try localNames() == ["dest"], "nothing was written next to the chosen folder")
        #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().appending(path: "escape.txt").path))
        #expect(try localNames(destination) == [".._top.txt", "Hostile"])
        #expect(try localNames(destination.appending(path: "Hostile")) == [".._.._escape.txt", "_", "a_b.txt"])
        #expect(try localNames(destination.appending(path: "Hostile/_")) == ["merged.txt"])
    }

    @Test func deviceReplaceSucceedsWithoutLeftovers() async throws {
        let memo = try await itemRef(["Documents", "메모.txt"])
        let download = try await folderRef(["Download"])
        _ = await run(.deviceCopy(items: [memo], destination: download, generation: 1, move: false))
        conflictAnswers = [.always(.replace)]
        let job = await run(.deviceCopy(items: [memo], destination: download, generation: 1, move: false))
        #expect(job.state == .completed && job.warnings.isEmpty)
        #expect(try await deviceNames(["Download"]).filter { $0 == "메모.txt" }.count == 1)
        #expect(manager.journal.entries.isEmpty)
        #expect(try await noStagingLeftovers())
    }
}

@Suite("FileNameRules")
struct FileNameRulesTests {
    @Test func validatesNames() {
        #expect(FileNameRules.validationError(for: "사진 2026") == nil)
        #expect(FileNameRules.validationError(for: "😀 emoji.txt") == nil)
        #expect(FileNameRules.validationError(for: ".hidden") == nil)
        for bad in ["", " ", ".", "..", "a/b", "a:b", "what?", " lead", "trail ", String(repeating: "가", count: 90),
                    ".phonebridge-x.part"] {
            #expect(FileNameRules.validationError(for: bad) == .invalidName, "\(bad)")
        }
    }

    @Test func uniqueNamesFollowFinderStyle() {
        #expect(FileNameRules.uniqueName(for: "a.txt", existing: []) == "a.txt")
        #expect(FileNameRules.uniqueName(for: "a.txt", existing: ["A.TXT"]) == "a 2.txt")
        #expect(FileNameRules.uniqueName(for: "a.txt", existing: ["a.txt", "a 2.txt"]) == "a 3.txt")
        #expect(FileNameRules.uniqueName(for: "폴더", existing: ["폴더"]) == "폴더 2")
        #expect(FileNameRules.uniqueName(for: "archive.tar.gz", existing: ["archive.tar.gz"]) == "archive.tar 2.gz")
    }

    @Test func deviceNamesBecomeOneMacPathComponent() {
        for ordinary in ["사진 2026.jpg", ".hidden", "a:b.txt", " lead", "trail ", "…", "😀"] {
            #expect(FileNameRules.singleComponent(ordinary) == ordinary)
        }
        #expect(FileNameRules.singleComponent("../../escape.txt") == ".._.._escape.txt")
        #expect(FileNameRules.singleComponent("a/b") == "a_b")
        #expect(FileNameRules.singleComponent("a\u{0}b") == "a_b")
        for reserved in ["", ".", ".."] {
            #expect(FileNameRules.singleComponent(reserved) == "_")
        }
    }

    @Test func localPathsStayInsideTheirFolder() throws {
        let folder = URL(filePath: "/tmp/pb-dest", directoryHint: .isDirectory)
        #expect(try LocalFileIO.child(of: folder, named: "../x").path(percentEncoded: false) == "/tmp/pb-dest/.._x")
        #expect(try LocalFileIO.child(of: folder, named: "..", isDirectory: true).lastPathComponent == "_")
        let deep = try LocalFileIO.descendant(of: folder, path: ["..", "..", "etc", "passwd"])
        #expect(deep.path(percentEncoded: false) == "/tmp/pb-dest/_/_/etc/passwd")
    }

    @Test func sanitizesMacNamesForDevice() {
        #expect(FileNameRules.sanitizedForDevice("a:b?.txt") == "a_b_.txt")
        #expect(FileNameRules.sanitizedForDevice("  ") == "_")
        #expect(FileNameRules.sanitizedForDevice(String(repeating: "😀", count: 200)).utf16.count <= 254)
        #expect(FileNameRules.temporaryName().hasPrefix(FileNameRules.temporaryPrefix))
    }
}
