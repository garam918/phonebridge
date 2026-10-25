import Foundation
import Testing
@testable import PhoneBridge

/// Transfers through the real chain DeviceBroker → MTPDeviceFileSystem →
/// MTPDeviceSession → MTPConnection, with file descriptors, against the
/// mock MTP backend (no hardware).
@MainActor
@Suite("Transfers via DeviceBroker session (mock MTP backend)", .serialized)
final class BrokerTransferTests {
    let monitor = MockUSBMonitor()
    let backend = MockMTPBackend()
    let local: URL
    let broker: DeviceBroker
    let manager: TransferManager

    init() throws {
        local = FileManager.default.temporaryDirectory.appending(path: "PBBrokerTransfer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let broker = DeviceBroker(monitor: monitor, backend: backend, configuration: .fast)
        self.broker = broker
        manager = TransferManager(fileSystemProvider: { broker.fileSystem(for: $0) }, volume: FakeVolume(available: nil),
                                  scratchDirectory: local.appending(path: ".scratch"))
        manager.conflictResolver = { _ in .always(.keepBoth) }
        broker.start()
    }

    deinit {
        try? FileManager.default.removeItem(at: local)
    }

    private var pixelID: DeviceID { USBDeviceSnapshot.fixture().logicalID }
    private let storageID: UInt32 = 0x0001_0001

    private func connect(registryID: UInt64 = 1) async throws -> any DeviceFileSystem {
        monitor.send(.attached(.fixture(registryID: registryID)))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        return try #require(broker.fileSystem(for: pixelID))
    }

    private var downloadFolder: DeviceFolderRef {
        DeviceFolderRef(id: FileItemID(deviceID: pixelID, storageID: storageID, objectID: MockMTPBackend.downloadID), path: ["Download"])
    }

    private func localFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: local.path).filter { $0 != ".scratch" && $0 != "src" }.sorted()
    }

    @Test func downloadAndUploadThroughFileDescriptors() async throws {
        let fs = try await connect()
        #expect(fs.capabilities.canRename && fs.capabilities.canMoveNatively && !fs.capabilities.canCopyNatively)

        let image = DeviceItemRef(item: FileItem(id: FileItemID(deviceID: pixelID, storageID: storageID, objectID: 0x12),
                                                 name: "IMG_0002.jpg", isFolder: false, size: 2_000, modified: nil),
                                  parentPath: ["DCIM", "Camera"])
        let download = manager.enqueue(.download(items: [image], generation: fs.generation, destination: local,
                                                 deleteSourceAfter: false), destinationName: "local")
        await manager.waitUntilIdle()
        #expect(download.state == .completed)
        #expect(try Data(contentsOf: local.appending(path: "IMG_0002.jpg")) == Data(repeating: 0x12, count: 2_000))

        let source = local.appending(path: "src/업로드 🎉.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let upload = manager.enqueue(.upload(sources: [source], destination: downloadFolder, generation: fs.generation,
                                             removeSourceAfter: false), destinationName: "Download")
        await manager.waitUntilIdle()
        #expect(upload.state == .completed)
        let uploaded = try #require(backend.object(named: "업로드 🎉.txt"))
        #expect(backend.content(of: uploaded.objectID) == payload)
        #expect(backend.children(of: MockMTPBackend.downloadID).allSatisfy { !FileNameRules.isTemporary($0.name) })

        let stats = backend.stats
        #expect(stats.maxConcurrent == 1, "MTP calls stay serialized during transfers")
        #expect(stats.mainThread == 0, "no blocking MTP I/O on the main thread")
    }

    @Test func unplugMidTransferThenRetryAfterReconnect() async throws {
        var fs = try await connect()
        let source = local.appending(path: "src/big.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 6 << 20).write(to: source)
        let seed = manager.enqueue(.upload(sources: [source], destination: downloadFolder, generation: fs.generation,
                                           removeSourceAfter: false), destinationName: "Download")
        await manager.waitUntilIdle()
        #expect(seed.state == .completed)
        let big = try #require(backend.object(named: "big.bin"))

        let oldGeneration = fs.generation
        backend.configure { $0.chunkDelay = 0.005 }
        let ref = DeviceItemRef(item: FileItem(id: FileItemID(deviceID: pixelID, storageID: storageID, objectID: big.objectID),
                                               name: "big.bin", isFolder: false, size: big.size, modified: nil),
                                parentPath: ["Download"])
        let job = manager.enqueue(.download(items: [ref], generation: fs.generation, destination: local,
                                            deleteSourceAfter: false), destinationName: "local")
        try await waitUntil { job.currentBytes > 0 }
        backend.unplug()
        monitor.send(.detached(registryID: 1))
        await manager.waitUntilIdle()
        guard case .failed(let error) = job.state else {
            Issue.record("expected failure after unplug, got \(job.state)")
            return
        }
        #expect(error.isRetryable)
        #expect(try localFiles().isEmpty, "staging file removed after unplug")

        // Same phone comes back with a new session: handles are re-resolved by path.
        backend.replug()
        backend.configure { $0.chunkDelay = 0 }
        fs = try await connect(registryID: 2)
        #expect(fs.generation != oldGeneration, "a new session has a new generation")
        let retried = try #require(manager.retry(job))
        await manager.waitUntilIdle()
        #expect(retried.state == .completed)
        #expect(LocalFileIO.fileSize(local.appending(path: "big.bin")) == 6 << 20)
    }

    @Test func hostileNamesFromTheDeviceAreMadeSingleComponents() async throws {
        let fs = try await connect()
        // Audit 2026-10-23 H4: the MTP boundary cleans names for every consumer
        // (transfers, previews, drag export and the Finder volume).
        backend.addObject(MTPObjectInfo(objectID: 0x7001, parentID: MockMTPBackend.downloadID, storageID: storageID,
                                        name: "../../escape.txt", size: 3, modified: nil, isFolder: false), content: Data("abc".utf8))
        backend.addObject(MTPObjectInfo(objectID: 0x7002, parentID: MockMTPBackend.downloadID, storageID: storageID,
                                        name: "..", size: 0, modified: nil, isFolder: true))
        let names = try await fs.contents(of: downloadFolder.id).map(\.name)
        #expect(names.contains(".._.._escape.txt") && names.contains("_"))
        #expect(!names.contains { $0.contains("/") || $0 == ".." })
        let item = try await fs.item(FileItemID(deviceID: pixelID, storageID: storageID, objectID: 0x7001))
        #expect(item.name == ".._.._escape.txt")
    }
}
