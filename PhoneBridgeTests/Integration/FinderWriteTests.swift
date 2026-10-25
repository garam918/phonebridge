import Foundation
import Testing
@testable import PhoneBridge

/// W1: the app side of Finder writes (FINDER_WRITE_PLAN.md) against the mock
/// device, with injected faults. Nothing here touches FSKit or a real device.
@MainActor
@Suite("Finder writes (coordinator + repository)", .serialized)
final class FinderWriteTests {
    static let storage = MockDeviceFileSystem.internalStorageID
    static let root = FileItemID.rootObjectID
    static let docsID: UInt32 = 0x200
    static let originalID: UInt32 = 0x201
    static let otherID: UInt32 = 0x202
    static let original = Data("원본 내용 — must survive\n".utf8)

    let buffers: URL
    let device: MockDeviceFileSystem
    let writes: FinderWriteCoordinator

    init() throws {
        buffers = FileManager.default.temporaryDirectory.appending(path: "PBWrites-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: buffers, withIntermediateDirectories: true)
        device = Self.makeDevice()
        writes = FinderWriteCoordinator(bufferDirectory: buffers, deleteGrace: .milliseconds(200))
    }

    deinit {
        try? FileManager.default.removeItem(at: buffers)
    }

    static func makeDevice(capabilities: FileSystemCapabilities = .full, readOnly: Bool = false) -> MockDeviceFileSystem {
        MockDeviceFileSystem(nodes: [
            .init(objectID: docsID, storageID: storage, parentID: root, name: "Documents", isFolder: true, size: nil, modified: nil),
            .init(objectID: originalID, storageID: storage, parentID: docsID, name: "보고서.txt", isFolder: false,
                  size: UInt64(original.count), modified: nil, content: original),
            .init(objectID: otherID, storageID: storage, parentID: docsID, name: "other.txt", isFolder: false,
                  size: 5, modified: nil, content: Data("other".utf8)),
        ], storages: [
            StorageInfo(id: storage, name: "내부 저장공간", capacity: 1_000_000, freeSpace: 500_000, kind: .internalStorage,
                        isReadOnly: readOnly),
        ], capabilities: capabilities)
    }

    private var docs: FileItemID { FileItemID(deviceID: .demo, storageID: Self.storage, objectID: Self.docsID) }
    private func id(_ objectID: UInt32) -> FileItemID { FileItemID(deviceID: .demo, storageID: Self.storage, objectID: objectID) }

    private func buffer(_ text: String) throws -> (name: String, size: UInt64) {
        let name = "buf-\(UUID().uuidString)"
        let data = Data(text.utf8)
        try data.write(to: buffers.appending(path: name))
        return (name, UInt64(data.count))
    }

    private func commit(_ text: String, as name: String = "보고서.txt", replacing: UInt32? = nil,
                        in fs: MockDeviceFileSystem? = nil) async throws -> FileItem {
        let (bufferName, size) = try buffer(text)
        return try await writes.commit(CommitRequest(parent: Self.docsID, name: name, replacing: replacing, bufferName: bufferName,
                                                     size: size, modified: nil),
                                       in: docs, freeSpace: nil, fileSystem: fs ?? device)
    }

    /// Names in Documents, staging/backup objects included.
    private func allNames(_ fs: MockDeviceFileSystem? = nil) -> [String] {
        (fs ?? device).children(of: Self.docsID, storageID: Self.storage).map(\.name).sorted()
    }

    private func visibleNames(_ fs: MockDeviceFileSystem? = nil) -> [String] {
        allNames(fs).filter { !FileNameRules.isTemporary($0) }
    }

    private func content(_ name: String, _ fs: MockDeviceFileSystem? = nil) -> Data? {
        (fs ?? device).nodes(named: name).first?.content
    }

    private func expectCode(_ code: Int32, _ body: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            try await body()
            Issue.record("expected errno \(code), got success", sourceLocation: sourceLocation)
        } catch let error as FinderIPCError {
            #expect(error.code == code, "got \(error.code) \(error.message)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Commit

    @Test func newFileIsStagedVerifiedAndNamed() async throws {
        let item = try await commit("새 파일\n", as: "새 파일.txt")
        #expect(item.name == "새 파일.txt")
        #expect(content("새 파일.txt") == Data("새 파일\n".utf8))
        #expect(allNames() == ["other.txt", "보고서.txt", "새 파일.txt"], "no staging object left")
        #expect(device.operationLog.contains(.rename), "uploaded under a staging name first")
    }

    @Test func replacingGoesThroughABackupAndLeavesNothingBehind() async throws {
        let item = try await commit("새 버전\n", replacing: Self.originalID)
        #expect(item.name == "보고서.txt")
        #expect(content("보고서.txt") == Data("새 버전\n".utf8))
        #expect(allNames() == ["other.txt", "보고서.txt"])
    }

    @Test func anUnexpectedExistingFileIsAConflict() async throws {
        await expectCode(EEXIST) { _ = try await self.commit("x", replacing: nil) }
        await expectCode(EEXIST) { _ = try await self.commit("x", replacing: Self.otherID) }
        #expect(content("보고서.txt") == Self.original)
        #expect(allNames() == ["other.txt", "보고서.txt"])
    }

    @Test func failedUploadKeepsTheOriginal() async throws {
        device.configureFaults { $0.failing[.upload] = .usbError(code: -7, detail: "mock pipe") }
        await expectCode(EIO) { _ = try await self.commit("새 버전", replacing: Self.originalID) }
        #expect(content("보고서.txt") == Self.original)
        #expect(allNames() == ["other.txt", "보고서.txt"])
    }

    @Test func partialUploadIsRemoved() async throws {
        device.configureFaults {
            $0.chunkSize = 4
            $0.failAfterBytes = 8
            $0.leavePartialUploads = true
        }
        await expectCode(EIO) { _ = try await self.commit("0123456789abcdef", replacing: Self.originalID) }
        #expect(allNames() == ["other.txt", "보고서.txt"], "the partial staging object is cleaned up")
        #expect(content("보고서.txt") == Self.original)
    }

    @Test func sizeMismatchAfterUploadKeepsTheOriginal() async throws {
        device.configureFaults { $0.corruptUploads = true }
        await expectCode(EIO) { _ = try await self.commit("새 버전입니다", replacing: Self.originalID) }
        #expect(content("보고서.txt") == Self.original)
        #expect(allNames() == ["other.txt", "보고서.txt"])
    }

    @Test func failedFinalRenameRestoresTheOriginal() async throws {
        // 1st rename: original → backup, 2nd: staging → final (fails).
        device.configureFaults { $0.failingCall[.rename] = (2, .protocolError(code: 0x2002, detail: "mock rename")) }
        await expectCode(EIO) { _ = try await self.commit("새 버전", replacing: Self.originalID) }
        #expect(content("보고서.txt") == Self.original)
        #expect(allNames() == ["other.txt", "보고서.txt"], "backup renamed back, staging removed")
    }

    @Test func unplugDuringUploadKeepsTheOriginal() async throws {
        device.configureFaults {
            $0.chunkSize = 2
            $0.chunkDelay = .milliseconds(20)
        }
        let task = Task { try await self.commit("0123456789abcdefghij", replacing: Self.originalID) }
        try await Task.sleep(for: .milliseconds(60))
        device.simulateDisconnect()
        do {
            _ = try await task.value
            Issue.record("expected a failure")
        } catch let error as FinderIPCError {
            #expect(error.code == ENXIO)
        }
        #expect(content("보고서.txt") == Self.original)
        #expect(device.node(Self.originalID)?.name == "보고서.txt")
    }

    @Test func badBuffersAndMissingSpaceAreRefusedBeforeAnyDeviceCall() async throws {
        await expectCode(EINVAL) {
            _ = try await self.writes.commit(CommitRequest(parent: Self.docsID, name: "a", replacing: nil, bufferName: "../escape",
                                                           size: 1, modified: nil), in: self.docs, freeSpace: nil, fileSystem: self.device)
        }
        let (name, size) = try buffer("12345")
        await expectCode(EIO) {
            _ = try await self.writes.commit(CommitRequest(parent: Self.docsID, name: "a", replacing: nil, bufferName: name,
                                                           size: size + 1, modified: nil), in: self.docs, freeSpace: nil, fileSystem: self.device)
        }
        await expectCode(ENOSPC) {
            _ = try await self.writes.commit(CommitRequest(parent: Self.docsID, name: "a", replacing: nil, bufferName: name,
                                                           size: size, modified: nil), in: self.docs, freeSpace: 2, fileSystem: self.device)
        }
        await expectCode(EINVAL) { _ = try await self.commit("x", as: "a:b") }
        await expectCode(EINVAL) { _ = try await self.commit("x", as: FileNameRules.temporaryName()) }
        #expect(!device.operationLog.contains(.upload))
    }

    @Test func withoutRenameNewFilesWorkButReplacingIsRefused() async throws {
        var capabilities = FileSystemCapabilities.full
        capabilities.canRename = false
        let device = Self.makeDevice(capabilities: capabilities)
        _ = try await commit("new", as: "new.txt", in: device)
        #expect(content("new.txt", device) == Data("new".utf8))
        await expectCode(ENOTSUP) { _ = try await self.commit("x", replacing: Self.originalID, in: device) }
        #expect(content("보고서.txt", device) == Self.original)
    }

    // MARK: - Delayed delete (D33)

    @Test func deletedFilesDisappearNowAndLeaveTheDeviceAfterTheGracePeriod() async throws {
        try await writes.delete(id(Self.originalID), in: docs, fileSystem: device)
        #expect(visibleNames() == ["other.txt"])
        #expect(allNames().count == 2, "kept under a hidden backup name for now")
        #expect(writes.pendingDeleteCount == 1)
        try await waitUntil { self.allNames() == ["other.txt"] }
        #expect(writes.pendingDeleteCount == 0)
    }

    @Test func finderReplaceDeletesFirstAndTheOriginalGoesOnlyAfterTheNewFileIsSafe() async throws {
        try await writes.delete(id(Self.originalID), in: docs, fileSystem: device)
        _ = try await commit("새 버전", replacing: nil)
        #expect(content("보고서.txt") == Data("새 버전".utf8))
        #expect(allNames() == ["other.txt", "보고서.txt"], "backup removed right after the commit")
        #expect(writes.pendingDeleteCount == 0)
    }

    @Test func failedReplacementBringsTheDeletedOriginalBack() async throws {
        try await writes.delete(id(Self.originalID), in: docs, fileSystem: device)
        device.configureFaults { $0.failing[.upload] = .disconnected }
        await expectCode(ENXIO) { _ = try await self.commit("새 버전", replacing: nil) }
        #expect(visibleNames() == ["other.txt", "보고서.txt"])
        #expect(content("보고서.txt") == Self.original)
        #expect(writes.pendingDeleteCount == 0)
    }

    @Test func pendingDeletesFinishOnUnmount() async throws {
        let slow = FinderWriteCoordinator(bufferDirectory: buffers, deleteGrace: .seconds(60))
        try await slow.delete(id(Self.originalID), in: docs, fileSystem: device)
        await slow.finishAllPendingDeletes(deviceID: .demo)
        #expect(allNames() == ["other.txt"])
    }

    // MARK: - The grace period waits for the replacement (audit 2026-10-23, H3)

    /// An upload that takes `chunks` × 40 ms and then fails (cable pulled).
    private func slowFailingUploads(chunks: Int = 16) {
        device.configureFaults {
            $0.chunkSize = 4
            $0.chunkDelay = .milliseconds(40)
            $0.failAfterBytes = UInt64(4 * (chunks - 1))
            $0.transferFailure = .disconnected
        }
    }

    @Test func slowReplacementThatFailsStillBringsTheOriginalBack() async throws {
        let quick = FinderWriteCoordinator(bufferDirectory: buffers, deleteGrace: .milliseconds(100))
        try await quick.delete(id(Self.originalID), in: docs, path: ["Documents"], fileSystem: device)
        slowFailingUploads() // runs well past the grace period
        let (bufferName, size) = try buffer(String(repeating: "새 버전 ", count: 8))
        await expectCode(ENXIO) {
            _ = try await quick.commit(CommitRequest(parent: Self.docsID, name: "보고서.txt", replacing: nil, bufferName: bufferName,
                                                     size: size, modified: nil),
                                       in: self.docs, freeSpace: nil, fileSystem: self.device)
        }
        #expect(content("보고서.txt") == Self.original, "the backup outlived its grace period while the upload ran")
        #expect(visibleNames() == ["other.txt", "보고서.txt"])
        #expect(quick.pendingDeleteCount == 0 && quick.journal.entries.isEmpty)
    }

    @Test func graceWaitsWhileFinderIsStillWritingTheReplacement() async throws {
        let quick = FinderWriteCoordinator(bufferDirectory: buffers, deleteGrace: .milliseconds(100))
        try await quick.delete(id(Self.originalID), in: docs, path: ["Documents"], fileSystem: device)
        // Finder's copy of the new file is still going into an extension buffer.
        let bufferName = FinderWritePolicy.newBufferName()
        let url = buffers.appending(path: bufferName)
        try Data("새 버전".utf8).write(to: url)
        let manifest = WriteBufferManifest(bufferName: bufferName, volume: VolumeAddress(deviceID: DeviceID.demo.rawValue,
                                                                                         storageID: Self.storage, generation: 1),
                                           volumeName: "Demo", folderPath: ["Documents"], fileName: "보고서.txt", state: .writing,
                                           updated: Date(), lastError: nil)
        try JSONEncoder().encode(manifest).write(to: buffers.appending(path: WriteBufferManifest.manifestName(for: bufferName)))
        let lock = WriteBufferLock.acquire(url)
        #expect(lock >= 0)

        try await Task.sleep(for: .milliseconds(450))
        #expect(quick.pendingDeleteCount == 1, "still waiting for the replacement")
        #expect(allNames().contains { $0.hasSuffix(".deleted") }, "the original is still on the device under its backup name")

        WriteBufferLock.release(lock) // the volume went away without committing
        try await waitUntil { self.allNames() == ["other.txt"] }
        #expect(quick.pendingDeleteCount == 0)
    }

    @Test func unmountDuringAReplacementLeavesTheOutcomeToIt() async throws {
        let slow = FinderWriteCoordinator(bufferDirectory: buffers, deleteGrace: .seconds(60))
        try await slow.delete(id(Self.originalID), in: docs, path: ["Documents"], fileSystem: device)
        slowFailingUploads()
        let (bufferName, size) = try buffer(String(repeating: "새 버전 ", count: 8))
        let commit = Task { @MainActor in
            try await slow.commit(CommitRequest(parent: Self.docsID, name: "보고서.txt", replacing: nil, bufferName: bufferName,
                                                size: size, modified: nil),
                                  in: self.docs, freeSpace: nil, fileSystem: self.device)
        }
        try await waitUntil { self.device.operationLog.contains(.upload) }
        await slow.finishAllPendingDeletes(deviceID: .demo)
        #expect(allNames().contains { $0.hasSuffix(".deleted") }, "the backup is not deleted under a running replacement")
        _ = await commit.result
        #expect(content("보고서.txt") == Self.original)
        #expect(slow.pendingDeleteCount == 0)
    }

    @Test func withoutRenameFinderCannotDeleteFiles() async throws {
        var capabilities = FileSystemCapabilities.full
        capabilities.canRename = false
        let device = Self.makeDevice(capabilities: capabilities)
        // Nowhere to hide the file until a replacement is safe (audit 2026-10-23, M5).
        await expectCode(ENOTSUP) { try await self.writes.delete(self.id(Self.originalID), in: self.docs, fileSystem: device) }
        #expect(content("보고서.txt", device) == Self.original)
    }

    @Test func foldersAreDeletedOnceOnlyDeferredFilesRemainInside() async throws {
        try await writes.delete(id(Self.originalID), in: docs, fileSystem: device)
        let rootFolder = FileItemID(deviceID: .demo, storageID: Self.storage, objectID: Self.root)
        await expectCode(ENOTEMPTY) { try await self.writes.delete(self.docs, in: rootFolder, fileSystem: self.device) }
        try await writes.delete(id(Self.otherID), in: docs, fileSystem: device)
        try await writes.delete(docs, in: rootFolder, fileSystem: device)
        #expect(device.node(Self.docsID) == nil)
        #expect(writes.pendingDeleteCount == 0)
    }

    // MARK: - Rename, move, folders

    @Test func renameAndRenameOverAnExpectedFile() async throws {
        let renamed = try await writes.rename(id(Self.otherID), in: docs, to: "다른 이름.txt", replacing: nil, fileSystem: device)
        #expect(renamed.name == "다른 이름.txt")
        await expectCode(EEXIST) {
            _ = try await self.writes.rename(self.id(Self.otherID), in: self.docs, to: "보고서.txt", replacing: nil, fileSystem: self.device)
        }
        // Atomic save: the temp file is renamed over the document.
        _ = try await writes.rename(id(Self.otherID), in: docs, to: "보고서.txt", replacing: Self.originalID, fileSystem: device)
        #expect(content("보고서.txt") == Data("other".utf8))
        #expect(allNames() == ["보고서.txt"])
    }

    @Test func failedRenameOverRestoresTheReplacedFile() async throws {
        device.configureFaults { $0.failingCall[.rename] = (2, .timeout) }
        await expectCode(ETIMEDOUT) {
            _ = try await self.writes.rename(self.id(Self.otherID), in: self.docs, to: "보고서.txt", replacing: Self.originalID,
                                             fileSystem: self.device)
        }
        #expect(content("보고서.txt") == Self.original)
        #expect(allNames() == ["other.txt", "보고서.txt"])
    }

    @Test func moveAcrossFoldersWithANewName() async throws {
        let rootFolder = FileItemID(deviceID: .demo, storageID: Self.storage, objectID: Self.root)
        let moved = try await writes.move(id(Self.otherID), from: docs, to: rootFolder, name: "옮긴.txt", replacing: nil, fileSystem: device)
        #expect(moved.name == "옮긴.txt")
        #expect(device.node(Self.otherID)?.parentID == Self.root)
        #expect(visibleNames() == ["보고서.txt"])
    }

    @Test func moveWithoutMoveObjectIsCrossDevice() async throws {
        var capabilities = FileSystemCapabilities.full
        capabilities.canMoveNatively = false
        let device = Self.makeDevice(capabilities: capabilities)
        let rootFolder = FileItemID(deviceID: .demo, storageID: Self.storage, objectID: Self.root)
        await expectCode(EXDEV) {
            _ = try await self.writes.move(self.id(Self.otherID), from: self.docs, to: rootFolder, name: "other.txt", replacing: nil,
                                           fileSystem: device)
        }
        #expect(device.node(Self.otherID)?.parentID == Self.docsID)
    }

    @Test func failedRenameAfterMoveMovesItBack() async throws {
        let rootFolder = FileItemID(deviceID: .demo, storageID: Self.storage, objectID: Self.root)
        device.configureFaults { $0.failing[.rename] = .timeout }
        await expectCode(ETIMEDOUT) {
            _ = try await self.writes.move(self.id(Self.otherID), from: self.docs, to: rootFolder, name: "새 이름.txt", replacing: nil,
                                           fileSystem: self.device)
        }
        #expect(device.node(Self.otherID)?.parentID == Self.docsID)
        #expect(device.node(Self.otherID)?.name == "other.txt")
    }

    @Test func createFolderChecksNamesAndConflicts() async throws {
        let folder = try await writes.createFolder(named: "새 폴더", in: docs, fileSystem: device)
        #expect(folder.isFolder)
        await expectCode(EEXIST) { _ = try await self.writes.createFolder(named: "새 폴더", in: self.docs, fileSystem: self.device) }
        await expectCode(EEXIST) { _ = try await self.writes.createFolder(named: "OTHER.TXT", in: self.docs, fileSystem: self.device) }
        await expectCode(EINVAL) { _ = try await self.writes.createFolder(named: "a/b", in: self.docs, fileSystem: self.device) }
    }

    @Test func requestsRunOneAtATime() async throws {
        device.configureFaults {
            $0.chunkSize = 4
            $0.chunkDelay = .milliseconds(5)
        }
        async let first = commit("first file contents", as: "1.txt")
        async let second = commit("second file contents", as: "2.txt")
        _ = try await (first, second)
        // Each commit is upload → item → rename; the second upload starts only
        // after the first commit's rename.
        let steps = device.operationLog.filter { $0 == .upload || $0 == .rename }
        #expect(steps == [.upload, .rename, .upload, .rename])
    }

    // MARK: - Repository gate

    @Test func repositoryRefusesWritesUnlessTurnedOn() async throws {
        let monitor = MockUSBMonitor()
        let broker = DeviceBroker(monitor: monitor, backend: MockMTPBackend(), configuration: .fast)
        let repository = MTPFileRepository(broker: broker, demoDevice: device, demoName: { "Demo" },
                                           cacheDirectory: buffers.appending(path: "cache"), writes: writes)
        let address = VolumeAddress(deviceID: DeviceID.demo.rawValue, storageID: Self.storage, generation: 1)
        let (bufferName, size) = try buffer("hello")
        let request = FinderRequest.commitFile(address, CommitRequest(parent: Self.docsID, name: "hello.txt", replacing: nil,
                                                                      bufferName: bufferName, size: size, modified: nil))

        guard case .writeCapabilities(let off) = await repository.handle(.writeCapabilities(address)).0 else { Issue.record(""); return }
        #expect(!off.allowsWrites)
        guard case .failure(let refused) = await repository.handle(request).0 else { Issue.record("expected EROFS"); return }
        #expect(refused.code == EROFS)

        repository.allowsWrites = true
        guard case .writeCapabilities(let on) = await repository.handle(.writeCapabilities(address)).0 else { Issue.record(""); return }
        #expect(on == WriteCapabilities(allowsWrites: true, canRename: true, canMove: true))
        guard case .entry(let entry) = await repository.handle(request).0 else { Issue.record("expected entry"); return }
        #expect(entry.name == "hello.txt" && entry.size == 5 && entry.parentID == Self.docsID)

        let stale = VolumeAddress(deviceID: DeviceID.demo.rawValue, storageID: Self.storage, generation: 2)
        guard case .failure(let old) = await repository.handle(.delete(stale, object: Self.otherID, parent: Self.docsID, parentPath: nil)).0 else {
            Issue.record("expected ESTALE")
            return
        }
        #expect(old.code == ESTALE)
    }

    @Test func readOnlyStorageNeverAllowsWrites() async throws {
        let device = Self.makeDevice(readOnly: true)
        let repository = MTPFileRepository(broker: DeviceBroker(monitor: MockUSBMonitor(), backend: MockMTPBackend()),
                                           demoDevice: device, demoName: { "Demo" }, cacheDirectory: buffers.appending(path: "cache"),
                                           writes: writes)
        repository.allowsWrites = true
        let address = VolumeAddress(deviceID: DeviceID.demo.rawValue, storageID: Self.storage, generation: 1)
        guard case .writeCapabilities(let caps) = await repository.handle(.writeCapabilities(address)).0 else { Issue.record(""); return }
        #expect(!caps.allowsWrites)
        guard case .failure(let error) = await repository.handle(.createFolder(address, parent: Self.docsID, parentPath: ["Documents"], name: "x")).0 else {
            Issue.record("expected EROFS")
            return
        }
        #expect(error.code == EROFS)
    }

    @Test func writeRequestsAreNeverResentAfterALostReply() {
        let address = VolumeAddress(deviceID: "d", storageID: 1, generation: 1)
        #expect(FinderRequest.read(address, object: 1, offset: 0, length: 1).isIdempotent)
        #expect(FinderRequest.writeCapabilities(address).isIdempotent)
        #expect(!FinderRequest.delete(address, object: 1, parent: 2, parentPath: nil).isIdempotent)
        #expect(!FinderRequest.commitFile(address, CommitRequest(parent: 1, name: "a", replacing: nil, bufferName: "b", size: 0,
                                                                 modified: nil)).isIdempotent)
    }
}

// MARK: - Over the socket

@MainActor
@Suite("Finder writes over IPC v2", .serialized)
final class FinderWriteIPCTests {
    let buffers: URL
    let device = FinderWriteTests.makeDevice()
    let repository: MTPFileRepository
    let socketURL = shortSocketURL()
    var server: FinderBrokerServer!

    init() throws {
        buffers = FileManager.default.temporaryDirectory.appending(path: "PBWritesIPC-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: buffers, withIntermediateDirectories: true)
        repository = MTPFileRepository(broker: DeviceBroker(monitor: MockUSBMonitor(), backend: MockMTPBackend()), demoDevice: device,
                                       demoName: { "Demo" }, cacheDirectory: buffers.appending(path: "cache"),
                                       writes: FinderWriteCoordinator(bufferDirectory: buffers, deleteGrace: .milliseconds(100)))
        repository.allowsWrites = true
        let repository = repository
        server = FinderBrokerServer(socketPath: socketURL.path,
                                    peerRequirement: PeerRequirement.forOwnSignature(identifiers: [FinderIPC.appBundleIdentifier,
                                                                                                   FinderIPC.extensionBundleIdentifier])) {
            await repository.handle($0)
        }
        try server.start()
    }

    deinit {
        server?.stop()
        try? FileManager.default.removeItem(at: buffers)
    }

    @Test func extensionStyleSequenceRoundTrips() async throws {
        let address = VolumeAddress(deviceID: DeviceID.demo.rawValue, storageID: FinderWriteTests.storage, generation: 1)
        let docs = FinderWriteTests.docsID
        let original = FinderWriteTests.originalID
        try Data("버퍼 내용".utf8).write(to: buffers.appending(path: "b1"))
        let size = UInt64(Data("버퍼 내용".utf8).count)
        let path = socketURL.path
        let result = try await Task.detached { () throws -> (WriteCapabilities, RemoteEntry, RemoteEntry, [String]) in
            let client = FinderBrokerClient(socketPath: path)
            let caps = try client.writeCapabilities(address)
            let folder = try client.createFolder(address, parent: docs, parentPath: ["Documents"], name: "사진")
            try client.delete(address, object: original, parent: docs, parentPath: ["Documents"])
            let file = try client.commitFile(address, CommitRequest(parent: docs, name: "보고서.txt", replacing: nil, bufferName: "b1",
                                                                    size: size, modified: 1_700_000_000))
            let moved = try client.move(address, object: file.objectID, from: docs, fromPath: ["Documents"], parent: folder.objectID,
                                        parentPath: ["Documents", "사진"], name: "보고서.txt", replacing: nil)
            _ = moved
            let names = try client.list(address, parent: docs).map(\.name).sorted()
            return (caps, folder, file, names)
        }.value
        #expect(result.0.allowsWrites)
        #expect(result.1.isFolder && result.1.name == "사진")
        #expect(result.2.size == size)
        #expect(result.3 == ["other.txt", "사진"], "the deleted original is hidden, the new file moved")
        #expect(device.nodes(named: "보고서.txt").count == 1)
        #expect(device.nodes(named: "보고서.txt").first?.content == Data("버퍼 내용".utf8))
    }
}

// MARK: - Extension policy (pure logic shared with the FSKit extension)

@Suite("Finder write policy (W0 conclusions)")
struct FinderWritePolicyTests {
    @Test func bookkeepingFilesStayOffTheDevice() {
        #expect(FinderWritePolicy.isShadowName("._사진.jpg"))
        #expect(FinderWritePolicy.isShadowName(".DS_Store"))
        #expect(!FinderWritePolicy.isShadowName(".nomedia"), "Android's own dot files are real files")
        #expect(!FinderWritePolicy.isShadowName("_x.txt"))
        #expect(FinderWritePolicy.isRefusedFolderName(".Trashes"))
        #expect(!FinderWritePolicy.isRefusedFolderName(".thumbnails"))
    }

    @Test func closeDecisions() {
        typealias P = FinderWritePolicy
        // Finder's empty placeholder: wait, it is usually deleted right away.
        #expect(P.closeAction(writersLeft: 0, isShadow: false, isOnDevice: false, isDirty: false, size: 0) == .commitLater)
        #expect(P.closeAction(writersLeft: 0, isShadow: false, isOnDevice: false, isDirty: true, size: 10) == .commit)
        #expect(P.closeAction(writersLeft: 1, isShadow: false, isOnDevice: false, isDirty: true, size: 10) == .none,
                "another writer still has it open")
        #expect(P.closeAction(writersLeft: 0, isShadow: true, isOnDevice: false, isDirty: true, size: 4096) == .none)
        #expect(P.closeAction(writersLeft: 0, isShadow: false, isOnDevice: true, isDirty: false, size: 10) == .none,
                "opened for writing but unchanged: no upload")
        #expect(P.closeAction(writersLeft: 0, isShadow: false, isOnDevice: true, isDirty: true, size: 0) == .commit,
                "truncating an existing file to zero is a real change")
    }

    @Test func bufferNamesAreValid() {
        let name = FinderWritePolicy.newBufferName()
        #expect(FinderIPC.isValidBufferName(name))
        #expect(name != FinderWritePolicy.newBufferName())
    }
}
