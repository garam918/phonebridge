import Foundation
import Testing
@testable import PhoneBridge

// MARK: - Test doubles

@MainActor
final class FakeVolumeMounter: VolumeMounting {
    var canMountProgrammatically = true
    /// nil: follows `canMountProgrammatically` (macOS 27 / 26).
    var supportOverride: FinderSupport?
    var support: FinderSupport { supportOverride ?? (canMountProgrammatically ? .full : .manualMount) }
    var status: FinderExtensionStatus = .enabled
    var failNextMount: String?
    private(set) var mounted: [URL: VolumeAddress] = [:]
    private(set) var mountCount = 0
    private(set) var unmountCount = 0
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func extensionStatus() async -> FinderExtensionStatus { status }

    var leftovers: [URL] = []
    func existingMounts() -> [URL] { leftovers }

    func mount(_ volume: MTPFileRepository.Volume) async throws -> URL {
        if let message = failNextMount {
            failNextMount = nil
            throw NSError(domain: "FakeMount", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        mountCount += 1
        let url = root.appending(path: "mnt-\(mountCount)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        mounted[url] = volume.address
        return url
    }

    func unmount(_ url: URL) async throws {
        unmountCount += 1
        mounted[url] = nil
        try? FileManager.default.removeItem(at: url)
    }

    func openExtensionSettings() -> Bool { true }
}

func shortSocketURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "pb-\(UUID().uuidString.prefix(8)).sock")
}

// MARK: - Protocol

@Suite("Finder IPC protocol")
struct FinderIPCProtocolTests {
    @Test func volumeURLRoundTrips() throws {
        let address = VolumeAddress(deviceID: "usb:18d1:SERIAL 1/한글", storageID: 0x0002_0001, generation: 42)
        let url = address.url
        #expect(url.scheme == "phonebridge" && url.host == "volume")
        #expect(VolumeAddress(url: url) == address)
        #expect(address.uuid == VolumeAddress(url: url)?.uuid, "UUID must be stable across processes")
        #expect(address.uuid != VolumeAddress(deviceID: address.deviceID, storageID: address.storageID, generation: 43).uuid)
        #expect(VolumeAddress(url: URL(string: "ftp://volume?device=x&storage=1&generation=1")!) == nil)
        #expect(VolumeAddress(url: URL(string: "phonebridge://volume?device=x&storage=zz&generation=1")!) == nil)
    }

    @Test func mountNamesAreASCII() {
        #expect(VolumeDescription.mountSafeName("Pixel 8 – Internal", fallback: "PhoneBridge Pixel 8") == "PhoneBridge Pixel 8",
                "an en dash alone makes the name unusable")
        #expect(VolumeDescription.mountSafeName("Pixel 8 - Internal shared storage", fallback: "PhoneBridge Pixel 8")
                == "Pixel 8 - Internal shared storage")
        #expect(VolumeDescription.mountSafeName("가람의 S25 Edge – 내장 저장공간", fallback: "PhoneBridge SM-S937N") == "PhoneBridge SM-S937N")
        #expect(VolumeDescription.mountSafeName("A/B", fallback: "PhoneBridge 한글 2") == "PhoneBridge 2")
        #expect(VolumeDescription.mountSafeName("데모", fallback: "갤럭시") == "PhoneBridge")
    }

    @Test func unmountHelperOnlyAcceptsThisBuildsVolumes() {
        let from = "phonebridge://volume?device=usb:04e8:X&storage=10001&generation=2"
        let on = "/Volumes/PhoneBridge SM-S937N"
        let own = FinderIPC.fileSystemShortName
        let other = own == "phonebridge" ? "phonebridgedev" : "phonebridge"
        #expect(VolumeUnmountPolicy.allows(fileSystemType: own, mountedFrom: from, mountedOn: on, requested: on))
        #expect(!VolumeUnmountPolicy.allows(fileSystemType: other, mountedFrom: from, mountedOn: on, requested: on),
                "development and release builds never unmount each other's volumes")
        #expect(!VolumeUnmountPolicy.allows(fileSystemType: "apfs", mountedFrom: "/dev/disk3s1", mountedOn: on, requested: on))
        #expect(!VolumeUnmountPolicy.allows(fileSystemType: own, mountedFrom: "/dev/disk4", mountedOn: on, requested: on))
        #expect(!VolumeUnmountPolicy.allows(fileSystemType: own, mountedFrom: from, mountedOn: "/private/tmp/x", requested: "/private/tmp/x"))
        #expect(!VolumeUnmountPolicy.allows(fileSystemType: own, mountedFrom: from, mountedOn: "/Volumes", requested: on + "/DCIM"))
        #expect(VolumeUnmountPolicy.check(path: "/") == EPERM, "the system volume is never unmounted")
        #expect(VolumeUnmountPolicy.check(path: "/nonexistent-\(UUID())") == ENOENT)
    }

    @Test func stagingObjectsAreShownOnlyOnDiagnosticMounts() {
        let address = VolumeAddress(deviceID: "d", storageID: 1, generation: 1)
        #expect(!VolumeAddress.showsStagingObjects(address.url))
        #expect(VolumeAddress.showsStagingObjects(URL(string: address.url.absoluteString + "&staging=1")!))
        #expect(VolumeAddress(url: URL(string: address.url.absoluteString + "&staging=1")!) == address)
        #expect(FinderIPC.temporaryPrefix == FileNameRules.temporaryPrefix)
    }

    @Test func messagesRoundTripThroughJSON() throws {
        let address = VolumeAddress(deviceID: "demo", storageID: 1, generation: 1)
        let requests: [FinderRequest] = [.hello(version: 1), .describe(address), .list(address, parent: remoteRootObjectID),
                                         .stat(address, object: 7), .read(address, object: 7, offset: 5_000_000_000, length: 65_536)]
        for request in requests {
            #expect(try JSONDecoder().decode(FinderRequest.self, from: JSONEncoder().encode(request)) == request)
        }
        let response = FinderResponse.entries([RemoteEntry(objectID: 1, parentID: remoteRootObjectID, name: "😀 사진.jpg",
                                                           isFolder: false, size: 5_000_000_000, modified: 1.5)])
        #expect(try JSONDecoder().decode(FinderResponse.self, from: JSONEncoder().encode(response)) == response)
    }
}

// MARK: - Repository

@MainActor
@Suite("MTP file repository (Finder read path)", .serialized)
final class MTPFileRepositoryTests {
    let monitor = MockUSBMonitor()
    let backend = MockMTPBackend()
    let broker: DeviceBroker
    let demo: MockDeviceFileSystem
    let cache: URL
    let repository: MTPFileRepository

    init() {
        broker = DeviceBroker(monitor: monitor, backend: backend, configuration: .fast)
        demo = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree() + [
            .init(objectID: 0x9100, storageID: MockDeviceFileSystem.internalStorageID, parentID: FileItemID.rootObjectID,
                  name: "big-4k-video.mp4", isFolder: false, size: 3 << 30, modified: Date()),
        ])
        cache = FileManager.default.temporaryDirectory.appending(path: "PBRepoCache-\(UUID().uuidString)", directoryHint: .isDirectory)
        repository = MTPFileRepository(broker: broker, demoDevice: demo, demoName: { "Demo" }, cacheDirectory: cache)
        broker.start()
    }

    deinit {
        try? FileManager.default.removeItem(at: cache)
    }

    private var pixelID: DeviceID { USBDeviceSnapshot.fixture().logicalID }

    private func connect(_ capabilities: MTPCapabilities) async throws -> VolumeAddress {
        backend.configure { $0.capabilities = capabilities }
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let record = try #require(broker.record(for: pixelID))
        return VolumeAddress(deviceID: pixelID.rawValue, storageID: 0x0001_0001, generation: record.generation)
    }

    @Test func listsDescribesAndStatsThroughTheBrokerSession() async throws {
        let address = try await connect([.rename])
        let description = try await repository.describe(address)
        #expect(description.name == "Google Pixel 8 – 내부 저장공간" && description.isReadOnly && !description.isDemo)
        let root = try await repository.list(address, parent: remoteRootObjectID)
        #expect(root.map(\.name) == ["DCIM", "Download", "notes.txt"])
        #expect(root.first { $0.name == "notes.txt" }?.size == 120)
        let camera = try await repository.list(address, parent: MockMTPBackend.cameraID)
        #expect(camera.map(\.name) == ["IMG_0002.jpg", "IMG_0010.jpg"])
        #expect(try await repository.stat(address, object: 0x13).size == 3_000)
        let volumes = repository.mountableVolumes(demoStorages: [])
        #expect(volumes.map(\.address) == [address])
    }

    @Test func partialReadsGoStraightToTheDevice() async throws {
        let address = try await connect([.rename, .partialGet])
        let data = try await repository.read(address, object: 0x12, offset: 100, length: 50)
        #expect(data == Data(repeating: 0x12, count: 50))
        let tail = try await repository.read(address, object: 0x12, offset: 1_990, length: 4_096)
        #expect(tail.count == 10, "short read at end of file")
        #expect(backend.transferCounts.partialReads == 2 && backend.transferCounts.fullDownloads == 0)
        #expect(repository.cachedFileCount == 0)
    }

    @Test func devicesWithoutPartialReadsAreServedFromAVerifiedCache() async throws {
        let address = try await connect([.rename])
        let first = try await repository.read(address, object: 0x13, offset: 0, length: 1_000)
        let second = try await repository.read(address, object: 0x13, offset: 2_500, length: 1_000)
        #expect(first == Data(repeating: 0x13, count: 1_000))
        #expect(second.count == 500)
        #expect(backend.transferCounts.fullDownloads == 1, "the file is downloaded once and reused")
        #expect(backend.transferCounts.partialReads == 0)
        let staging = (try FileManager.default.contentsOfDirectory(atPath: cache.path)).filter { FileNameRules.isTemporary($0) }
        #expect(staging.isEmpty)

        repository.invalidateCache(deviceID: pixelID.rawValue)
        #expect(repository.cachedFileCount == 0)
        _ = try await repository.read(address, object: 0x13, offset: 0, length: 10)
        #expect(backend.transferCounts.fullDownloads == 2)
    }

    @Test func staleSessionAndMissingDeviceMapToPOSIXErrors() async throws {
        let address = try await connect([.rename])
        var stale = address
        stale.generation += 99
        await #expect(throws: FinderIPCError(code: ESTALE, message: "session changed")) {
            _ = try await self.repository.list(stale, parent: remoteRootObjectID)
        }
        let unknown = VolumeAddress(deviceID: "usb:dead:beef", storageID: 1, generation: 1)
        do {
            _ = try await repository.list(unknown, parent: remoteRootObjectID)
            Issue.record("expected ENXIO")
        } catch {
            #expect(error.code == ENXIO)
        }
        do {
            _ = try await repository.stat(address, object: 0xDEAD)
            Issue.record("expected ENOENT")
        } catch {
            #expect(error.code == ENOENT)
        }
    }

    @Test func readsAtOffsetsBeyondFourGiBBoundaryAreExact() async throws {
        let address = VolumeAddress(deviceID: DeviceID.demo.rawValue, storageID: MockDeviceFileSystem.internalStorageID, generation: 1)
        let offset: UInt64 = (5 << 29) + 123 // 2.5 GiB + 123
        let data = try await repository.read(address, object: 0x9100, offset: offset, length: 64 << 10)
        #expect(data.count == 64 << 10)
        #expect(data.first == MockDeviceFileSystem.pattern(objectID: 0x9100, offset: offset, count: 1).first)
        let last = try await repository.read(address, object: 0x9100, offset: (3 << 30) - 10, length: 100)
        #expect(last.count == 10)
    }

    @Test func finderWritesReachRealDevicesOnlyWhenAllowed() async throws {
        let address = try await connect([.rename, .moveObject, .partialGet])
        repository.allowsWrites = true
        guard case .writeCapabilities(let caps) = await repository.handle(.writeCapabilities(address)).0 else {
            Issue.record("expected capabilities")
            return
        }
        #expect(!caps.allowsWrites, "only the demo device until the real-device check (W5)")
        guard case .failure(let error) = await repository.handle(.createFolder(address, parent: remoteRootObjectID, parentPath: [], name: "x")).0 else {
            Issue.record("expected EROFS")
            return
        }
        #expect(error.code == EROFS)
        repository.allowsRealDeviceWrites = true
        guard case .writeCapabilities(let allowed) = await repository.handle(.writeCapabilities(address)).0 else { return }
        #expect(allowed.allowsWrites)
    }

    @Test func realDeviceWritesStayInsideTheTestFolder() async throws {
        let address = try await connect([.rename, .moveObject, .partialGet])
        repository.allowsWrites = true
        repository.allowsRealDeviceWrites = true
        repository.realDeviceWriteScope = "PhoneBridge W5 테스트"
        func code(_ request: FinderRequest) async -> Int32? {
            if case .failure(let error) = await repository.handle(request).0 { return error.code }
            return nil
        }
        // Anywhere else, or with an unknown path: refused before any device call.
        #expect(await code(.createFolder(address, parent: remoteRootObjectID, parentPath: [], name: "다른 폴더")) == EACCES)
        #expect(await code(.createFolder(address, parent: MockMTPBackend.dcimID, parentPath: ["DCIM"], name: "x")) == EACCES)
        #expect(await code(.createFolder(address, parent: MockMTPBackend.dcimID, parentPath: nil, name: "x")) == EACCES)
        #expect(await code(.delete(address, object: MockMTPBackend.cameraID, parent: MockMTPBackend.dcimID, parentPath: ["DCIM"])) == EACCES)
        #expect(await code(.rename(address, object: MockMTPBackend.dcimID, parent: remoteRootObjectID, parentPath: [], name: "y",
                                   replacing: nil)) == EACCES)
        #expect(await code(.commitFile(address, CommitRequest(parent: MockMTPBackend.downloadID, parentPath: ["Download"], name: "a",
                                                              replacing: nil, bufferName: "w-x", size: 0, modified: nil))) == EACCES)
        // The test folder itself at the root, and anything inside it.
        guard case .entry(let folder) = await repository.handle(.createFolder(address, parent: remoteRootObjectID, parentPath: [],
                                                                              name: "PhoneBridge W5 테스트")).0 else {
            Issue.record("the test folder should be allowed")
            return
        }
        guard case .entry = await repository.handle(.createFolder(address, parent: folder.objectID,
                                                                  parentPath: ["PhoneBridge W5 테스트"], name: "하위")).0 else {
            Issue.record("inside the test folder should be allowed")
            return
        }
        #expect(await code(.move(address, object: MockMTPBackend.cameraID, from: MockMTPBackend.dcimID, fromPath: ["DCIM"],
                                 parent: folder.objectID, parentPath: ["PhoneBridge W5 테스트"], name: "Camera", replacing: nil)) == EACCES,
                "nothing may be moved in from outside")
        #expect(await code(.delete(address, object: MockMTPBackend.dcimID, parent: remoteRootObjectID, parentPath: [])) == EACCES)

        // Root-move check: a test *file* may go to the root and back, nothing else.
        let dcimFile = try #require(backend.children(of: MockMTPBackend.cameraID).first { !$0.isFolder })
        #expect(await code(.move(address, object: dcimFile.objectID, from: MockMTPBackend.cameraID, fromPath: ["DCIM", "Camera"],
                                 parent: remoteRootObjectID, parentPath: [], name: "PhoneBridge W5 테스트 x", replacing: nil)) == EACCES,
                "a file from outside the test folder never moves")
        guard case .entry(let probe) = await repository.handle(.createFolder(address, parent: folder.objectID,
                                                                             parentPath: ["PhoneBridge W5 테스트"], name: "PhoneBridge W5 테스트 폴더")).0 else {
            Issue.record("folder inside")
            return
        }
        #expect(await code(.move(address, object: probe.objectID, from: folder.objectID, fromPath: ["PhoneBridge W5 테스트"],
                                 parent: remoteRootObjectID, parentPath: [], name: "PhoneBridge W5 테스트 폴더", replacing: nil)) == EACCES,
                "folders never go to the root")
    }

    @Test func demoDeviceCanBeExcluded() async throws {
        repository.includeDemoDevice = false
        let address = VolumeAddress(deviceID: DeviceID.demo.rawValue, storageID: MockDeviceFileSystem.internalStorageID, generation: 1)
        do {
            _ = try await repository.describe(address)
            Issue.record("expected ENXIO")
        } catch {
            #expect(error.code == ENXIO)
        }
    }
}

// MARK: - Real socket round trips

@MainActor
@Suite("Finder IPC over a real Unix socket", .serialized)
final class FinderIPCRoundTripTests {
    let demo = MockDeviceFileSystem()
    let monitor = MockUSBMonitor()
    let backend = MockMTPBackend()
    let broker: DeviceBroker
    let repository: MTPFileRepository
    let socketURL = shortSocketURL()
    var server: FinderBrokerServer!

    init() throws {
        broker = DeviceBroker(monitor: monitor, backend: backend, configuration: .fast)
        repository = MTPFileRepository(broker: broker, demoDevice: demo, demoName: { "Demo" },
                                       cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "PBIPC-\(UUID().uuidString)"))
        server = makeServer(requirement: Self.ownRequirement)
        try server.start()
        broker.start()
    }

    deinit {
        server?.stop()
    }

    static let ownRequirement = PeerRequirement.forOwnSignature(identifiers: [FinderIPC.appBundleIdentifier,
                                                                             FinderIPC.extensionBundleIdentifier])

    private func makeServer(requirement: String?) -> FinderBrokerServer {
        let repository = repository
        return FinderBrokerServer(socketPath: socketURL.path, peerRequirement: requirement) { request in
            await repository.handle(request)
        }
    }

    /// Restarts the server with `requirement` and reports whether this test
    /// process is refused as a client.
    private func isRefused(under requirement: String?) async throws -> Bool {
        server.stop()
        server = makeServer(requirement: requirement)
        try server.start()
        let path = socketURL.path
        return try await offMain {
            let client = FinderBrokerClient(socketPath: path)
            do {
                try client.connect()
                return false
            } catch {
                return true
            }
        }
    }

    private var demoAddress: VolumeAddress {
        VolumeAddress(deviceID: DeviceID.demo.rawValue, storageID: MockDeviceFileSystem.internalStorageID, generation: 1)
    }

    /// Client calls block; run them off the main actor the repository needs.
    private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached { try body() }.value
    }

    @Test func clientBrowsesAndReadsTheDemoVolume() async throws {
        let path = socketURL.path
        let address = demoAddress
        let (description, root, dcim, bytes) = try await offMain {
            let client = FinderBrokerClient(socketPath: path)
            try client.connect()
            let description = try client.describe(address)
            let root = try client.list(address, parent: remoteRootObjectID)
            let dcimID = root.first { $0.name == "DCIM" }!.objectID
            let camera = try client.list(address, parent: try client.list(address, parent: dcimID).first { $0.name == "Camera" }!.objectID)
            let image = camera.first!
            let bytes = try client.read(address, object: image.objectID, offset: 1_000, length: 4_096)
            return (description, root, camera, bytes)
        }
        #expect(description.isDemo && description.name == "Demo – 내부 저장공간")
        #expect(root.map(\.name).contains("Documents"))
        #expect(dcim.count == 13)
        #expect(bytes == MockDeviceFileSystem.pattern(objectID: dcim[0].objectID, offset: 1_000, count: 4_096))
    }

    @Test func errorsArriveAsPOSIXCodes() async throws {
        let path = socketURL.path
        let address = demoAddress
        let code: Int32 = try await offMain {
            let client = FinderBrokerClient(socketPath: path)
            do {
                _ = try client.stat(address, object: 0xBEEF)
                return 0
            } catch {
                return (error as? FinderIPCError)?.code ?? -1
            }
        }
        #expect(code == ENOENT)
    }

    @Test func clientReconnectsAfterServerRestart() async throws {
        let path = socketURL.path
        let address = demoAddress
        let client = FinderBrokerClient(socketPath: path)
        _ = try await offMain { try client.list(address, parent: remoteRootObjectID) }
        server.stop()
        server = makeServer(requirement: PeerRequirement.forOwnSignature(identifiers: [FinderIPC.appBundleIdentifier]))
        try server.start()
        let again = try await offMain { try client.list(address, parent: remoteRootObjectID) }
        #expect(!again.isEmpty)
    }

    @Test func unknownCodeSignaturesAreRejected() async throws {
        #expect(try await isRefused(under: PeerRequirement.forOwnSignature(identifiers: ["com.example.not-phonebridge"])))
    }

    // Audit 2026-10-23 H2: this test process carries the app's signing
    // identifier, like a binary ad-hoc signed with `codesign -i`. Before the
    // fix the identifier alone was enough to get in.

    @Test func matchingIdentifierFromAnotherTeamIsRejected() async throws {
        let otherTeam = PeerRequirement.text(identifiers: [FinderIPC.appBundleIdentifier, FinderIPC.extensionBundleIdentifier],
                                             team: "ZZZZZZZZZZ", ownCDHash: nil)
        #expect(try await isRefused(under: otherTeam))
    }

    @Test func matchingIdentifierFromAnotherBinaryIsRejected() async throws {
        let otherBinary = PeerRequirement.text(identifiers: [FinderIPC.appBundleIdentifier, FinderIPC.extensionBundleIdentifier],
                                               team: nil, ownCDHash: Data(repeating: 0xAB, count: 20))
        #expect(try await isRefused(under: otherBinary))
    }

    @Test func serverWithoutRequirementRefusesEveryClient() async throws {
        #expect(try await isRefused(under: nil))
        #expect(try await !isRefused(under: Self.ownRequirement), "the same process is let in under its own requirement")
    }

    @Test func appAndFinderShareOneSerializedSession() async throws {
        backend.configure { $0.callDelay = 0.002 }
        monitor.send(.attached(.fixture()))
        let pixelID = USBDeviceSnapshot.fixture().logicalID
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let record = try #require(broker.record(for: pixelID))
        let address = VolumeAddress(deviceID: pixelID.rawValue, storageID: 0x0001_0001, generation: record.generation)
        let fileSystem = try #require(broker.fileSystem(for: pixelID))
        let browser = BrowserViewModel()
        let opensBefore = backend.stats.open

        let path = socketURL.path
        let finderReads = Task.detached {
            let client = FinderBrokerClient(socketPath: path)
            var total = 0
            for _ in 0..<15 {
                total += try client.read(address, object: 0x12, offset: 0, length: 500).count
                total += try client.list(address, parent: MockMTPBackend.cameraID).count
            }
            return total
        }
        for _ in 0..<5 {
            await browser.open(fileSystem, storage: record.storages[0])
        }
        let total = try await finderReads.value
        #expect(total == 15 * (500 + 2))
        #expect(browser.items.map(\.name) == ["DCIM", "Download", "notes.txt"])
        let stats = backend.stats
        #expect(stats.open == opensBefore, "Finder must not open its own MTP session")
        #expect(stats.maxConcurrent == 1)
        #expect(stats.mainThread == 0)
    }
}

// MARK: - Mount manager (fake FSKit mounter)

@MainActor
@Suite("Finder integration manager", .serialized)
final class FinderIntegrationManagerTests {
    let monitor = MockUSBMonitor()
    let backend = MockMTPBackend()
    let mounter: FakeVolumeMounter
    let model: AppModel
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "PBMount-\(UUID().uuidString)", directoryHint: .isDirectory)
        mounter = FakeVolumeMounter(root: root)
        let defaults = freshDefaults()
        defaults.set(false, forKey: AppSettings.Key.showDemoDevice)
        defaults.set(true, forKey: AppSettings.Key.finderIntegration)
        let broker = DeviceBroker(monitor: monitor, backend: backend, configuration: .fast)
        let socket = shortSocketURL()
        model = AppModel(broker: broker, localization: LocalizationManager(defaults: defaults), settings: AppSettings(defaults: defaults),
                         localAccess: LocalAccessManager(defaults: defaults, defaultFolder: FileManager.default.temporaryDirectory),
                         volumeMounter: mounter, finderSocketURL: { socket })
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var pixelID: DeviceID { USBDeviceSnapshot.fixture().logicalID }
    private var volumeID: String { "\(pixelID.rawValue)|\(0x0001_0001 as UInt32)" }

    private func mountedURL() -> URL? { model.finder.states[volumeID]?.mountURL }

    @Test func autoMountsOnConnectAndCleansUpOnUnplug() async throws {
        await model.start()
        #expect(model.finder.serverStatus != .stopped)
        if case .failed(let message) = model.finder.serverStatus { Issue.record("server failed: \(message)") }

        monitor.send(.attached(.fixture()))
        try await waitUntil { self.mountedURL() != nil }
        #expect(mounter.mounted.count == 1)

        monitor.send(.detached(registryID: 1))
        try await waitUntil { self.mounter.mounted.isEmpty }
        #expect(model.finder.states[volumeID] == .unmounted || model.finder.states[volumeID] == nil)
        #expect(mounter.unmountCount == 1)
    }

    @Test func volumesLeftByAnEarlierRunAreRemovedAtStart() async throws {
        let leftover = root.appending(path: "PhoneBridge SM-S937N", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        mounter.leftovers = [leftover]
        await model.start()
        #expect(mounter.unmountCount == 1)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func leftoverCleanupNeverTouchesVolumesOfThisRun() async throws {
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { self.mountedURL() != nil }
        mounter.leftovers = [try #require(mountedURL())]
        await model.finder.removeLeftoverMounts()
        #expect(mounter.unmountCount == 0)
        #expect(mounter.mounted.count == 1)
    }

    @Test func turningWritesOnOrOffRemountsMountedVolumes() async throws {
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { self.mountedURL() != nil }
        #expect(!model.finder.repository.allowsWrites)
        let volume = try #require(model.finder.volumes.first)
        #expect(!model.finder.acceptsWrites(volume))

        await model.finder.setWritesEnabled(true)
        #expect(model.settings.finderWritesEnabled && model.finder.repository.allowsWrites)
        #expect(mounter.unmountCount == 1 && mounter.mountCount == 2, "remounted so the extension sees the new mode")
        #expect(mountedURL() != nil)
        #expect(!model.finder.acceptsWrites(volume), "real devices need their own setting")
        model.finder.repository.allowsRealDeviceWrites = true
        #expect(model.finder.acceptsWrites(volume))

        await model.finder.setWritesEnabled(true)
        #expect(mounter.mountCount == 2, "no change, no remount")

        await model.finder.setWritesEnabled(false)
        #expect(!model.finder.repository.allowsWrites && !model.settings.finderWritesEnabled)
        #expect(mounter.unmountCount == 2 && mounter.mountCount == 3)
    }

    @Test func macOS15HasNoFinderIntegration() async throws {
        mounter.supportOverride = .unavailable
        model.settings.finderIntegrationEnabled = true
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { self.model.browser.phase == .loaded }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.finder.isAvailable && !model.finder.isEnabled)
        #expect(model.finder.serverStatus == .stopped, "no broker server without Finder volumes")
        #expect(mounter.mountCount == 0)
        await model.finder.setEnabled(true)
        #expect(mounter.mountCount == 0 && model.finder.serverStatus == .stopped)
        #expect(model.browser.items.isEmpty == false, "the app itself works as usual")
    }

    @Test func supportLevelFollowsTheRunningMacOS() {
        // This Mac runs macOS 27 or later; the level is computed, not configured.
        if #available(macOS 27.0, *) { #expect(FinderSupport.current == .full) }
        #expect(SystemVolumeMounter().support == FinderSupport.current)
    }

    @Test func writesStayOffByDefault() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(!settings.finderWritesEnabled)
        #expect(!settings.finderWritesRealDevices)
    }

    @Test func realDeviceWritesAreASettingThatRemounts() async throws {
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { self.mountedURL() != nil }
        let volume = try #require(model.finder.volumes.first)
        await model.finder.setWritesEnabled(true)
        let mountsBefore = mounter.mountCount
        #expect(!model.finder.acceptsWrites(volume))

        await model.finder.setRealDeviceWritesEnabled(true)
        #expect(model.settings.finderWritesRealDevices && model.finder.repository.allowsRealDeviceWrites)
        #expect(model.finder.acceptsWrites(volume))
        #expect(mounter.mountCount == mountsBefore + 1, "remounted writable")

        await model.finder.setWritesEnabled(false)
        #expect(!model.finder.acceptsWrites(volume), "the real-device option needs Finder writes on")
        await model.finder.setRealDeviceWritesEnabled(false)
        #expect(!model.finder.repository.allowsRealDeviceWrites)
    }

    @Test func realDeviceWriteSettingIsSavedAndTheDiagnosticsArgumentStillWorks() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.finderWritesRealDevices = true
        #expect(AppSettings(defaults: defaults).finderWritesRealDevices, "saved")

        let launched = freshDefaults()
        launched.set("YES", forKey: AppSettings.Key.diagnosticsRealDeviceWrites)
        #expect(AppSettings(defaults: launched).finderWritesRealDevices)
    }

    @Test func safeDisconnectUnmountsFromFinderAndClosesTheSession() async throws {
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { self.mountedURL() != nil }
        model.requestSafeDisconnect(pixelID)
        try await waitUntil { self.model.broker.record(for: self.pixelID)?.state == .safelyDisconnected }
        #expect(mounter.mounted.isEmpty && mounter.unmountCount == 1)
        #expect(backend.stats.close == 1)
        guard case .safelyDisconnected = model.notice?.kind else {
            Issue.record("expected the unplug notice, got \(String(describing: model.notice?.kind))")
            return
        }
    }

    @Test func remountsWithTheNewSessionAfterReconnect() async throws {
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { self.mountedURL() != nil }
        let firstGeneration = try #require(mounter.mounted.values.first?.generation)

        monitor.send(.detached(registryID: 1))
        try await waitUntil { self.model.broker.record(for: self.pixelID)?.state == .reconnecting }
        monitor.send(.attached(.fixture(registryID: 2)))
        try await waitUntil { self.mounter.mounted.values.first.map { $0.generation != firstGeneration } ?? false }
        #expect(mounter.mounted.count == 1)
        #expect(mounter.mountCount == 2 && mounter.unmountCount == 1)
    }

    @Test func repeatedManualMountAndUnmount() async throws {
        model.settings.finderAutoMount = false
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { !self.model.finder.volumes.isEmpty }
        let volume = try #require(model.finder.volumes.first)
        for _ in 0..<10 {
            await model.finder.mount(volume)
            #expect(model.finder.state(of: volume).mountURL != nil)
            await model.finder.unmount(volume)
            #expect(model.finder.state(of: volume) == .unmounted)
        }
        #expect(mounter.mountCount == 10 && mounter.unmountCount == 10 && mounter.mounted.isEmpty)
    }

    @Test func mountFailureIsReportedAndRetryable() async throws {
        model.settings.finderAutoMount = false
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { !self.model.finder.volumes.isEmpty }
        let volume = try #require(model.finder.volumes.first)
        mounter.failNextMount = "Module is disabled"
        await model.finder.mount(volume)
        #expect(model.finder.state(of: volume) == .failed("Module is disabled"))
        await model.finder.mount(volume)
        #expect(model.finder.state(of: volume).mountURL != nil)
    }

    @Test func disablingUnmountsEverythingAndStopsTheServer() async throws {
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { self.mountedURL() != nil }
        await model.finder.setEnabled(false)
        #expect(mounter.mounted.isEmpty)
        #expect(model.finder.serverStatus == .stopped)
        let volume = try #require(model.finder.volumes.first)
        await model.finder.mount(volume)
        #expect(model.finder.state(of: volume) == .failed("disabled"))
    }

    @Test func missingAppGroupIsReported() async throws {
        let defaults = freshDefaults()
        defaults.set(true, forKey: AppSettings.Key.finderIntegration)
        let broker = DeviceBroker(monitor: MockUSBMonitor(), backend: MockMTPBackend(), configuration: .fast)
        let model = AppModel(broker: broker, localization: LocalizationManager(defaults: defaults), settings: AppSettings(defaults: defaults),
                             localAccess: LocalAccessManager(defaults: defaults, defaultFolder: FileManager.default.temporaryDirectory),
                             volumeMounter: mounter, finderSocketURL: { nil })
        await model.start(startBroker: false)
        #expect(model.finder.serverStatus == .failed("app-group-unavailable"))
        let volume = try #require(model.finder.volumes.first { $0.isDemo })
        await model.finder.mount(volume)
        #expect(model.finder.state(of: volume) == .failed("app-group-unavailable"))
    }
}
