import Foundation
import Testing
@testable import PhoneBridge

/// An iPhone's camera roll as Image Capture would list it (D75).
final class FakeCameraBackend: CameraBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CameraEntry]
    private var data: [UInt32: Data]
    private var deletedIDs: [UInt32] = []
    /// Image Capture may return fewer bytes than asked for.
    let maxReadLength: Int
    var restricted = false

    static let dcim: UInt32 = 1, apple100: UInt32 = 2, emptyFolder: UInt32 = 3
    static let photo: UInt32 = 10, video: UInt32 = 11

    init(maxReadLength: Int = 7) {
        self.maxReadLength = maxReadLength
        let photo = Data((0..<100).map { UInt8($0) })
        let video = Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        entries = [
            CameraEntry(id: Self.dcim, parentID: FileItemID.rootObjectID, name: "DCIM", isFolder: true, size: nil, modified: nil),
            CameraEntry(id: Self.apple100, parentID: Self.dcim, name: "100APPLE", isFolder: true, size: nil, modified: nil),
            CameraEntry(id: Self.emptyFolder, parentID: Self.dcim, name: "101APPLE", isFolder: true, size: nil, modified: nil),
            CameraEntry(id: Self.photo, parentID: Self.apple100, name: "IMG_0001.HEIC", isFolder: false,
                        size: UInt64(photo.count), modified: date),
            CameraEntry(id: Self.video, parentID: Self.apple100, name: "IMG_0002.MOV", isFolder: false,
                        size: UInt64(video.count), modified: date),
        ]
        data = [Self.photo: photo, Self.video: video]
    }

    var deleted: [UInt32] { lock.withLock { deletedIDs } }
    func content(_ id: UInt32) -> Data? { lock.withLock { data[id] } }

    func catalog() async throws(DeviceError) -> [CameraEntry] {
        if restricted { throw .accessDenied }
        return lock.withLock { entries }
    }

    func read(_ id: UInt32, offset: UInt64, length: Int) async throws(DeviceError) -> Data {
        guard let bytes = lock.withLock({ data[id] }) else { throw .objectNotFound }
        let start = Int(min(offset, UInt64(bytes.count)))
        let end = min(bytes.count, start + min(length, maxReadLength))
        return bytes.subdata(in: start..<end)
    }

    func thumbnail(_ id: UInt32) async throws(DeviceError) -> Data {
        Data([0xFF, 0xD8])
    }

    func delete(_ ids: [UInt32]) async throws(DeviceError) {
        lock.withLock {
            deletedIDs += ids
            entries.removeAll { ids.contains($0.id) }
            for id in ids { data[id] = nil }
        }
    }
}

@MainActor
@Suite("iPhone/iPad photos (fake Image Capture)", .serialized)
final class AppleDeviceTests {
    let deviceID = DeviceID("ios:00008110-TEST")
    let backend = FakeCameraBackend()
    let fs: ImageCaptureFileSystem
    let local: URL

    init() throws {
        fs = ImageCaptureFileSystem(deviceID: deviceID, generation: 1, backend: backend, storageName: "사진 및 동영상")
        local = FileManager.default.temporaryDirectory.appending(path: "PBAppleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: local)
    }

    private var root: FileItemID { .root(deviceID: deviceID, storageID: ImageCaptureFileSystem.storageID) }

    private func folder(_ objectID: UInt32) -> FileItemID {
        FileItemID(deviceID: deviceID, storageID: ImageCaptureFileSystem.storageID, objectID: objectID)
    }

    private func ref(_ objectID: UInt32, parentPath: [String] = ["DCIM", "100APPLE"]) async throws -> DeviceItemRef {
        DeviceItemRef(item: try await fs.item(folder(objectID)), parentPath: parentPath)
    }

    private func transfers() -> TransferManager {
        let fs = fs
        let manager = TransferManager(fileSystemProvider: { $0 == fs.deviceID ? fs : nil }, volume: FakeVolume(available: nil),
                                      scratchDirectory: local.appending(path: ".scratch"))
        manager.conflictResolver = { _ in .always(.skip) }
        return manager
    }

    private func run(_ request: TransferRequest) async -> TransferJob {
        let manager = transfers()
        let job = manager.enqueue(request, destinationName: "test")
        await manager.waitUntilIdle()
        return job
    }

    // MARK: - File system

    @Test func browsesTheCameraRollFolders() async throws {
        #expect(try await fs.storages().map(\.name) == ["사진 및 동영상"])
        #expect(try await fs.contents(of: root).map(\.name) == ["DCIM"])
        #expect(try await fs.contents(of: folder(FakeCameraBackend.dcim)).map(\.name).sorted() == ["100APPLE", "101APPLE"])
        let photos = try await fs.contents(of: folder(FakeCameraBackend.apple100))
        #expect(photos.map(\.name) == ["IMG_0001.HEIC", "IMG_0002.MOV"])
        #expect(photos.allSatisfy { !$0.isFolder && $0.size != nil && $0.modified != nil })
        #expect(try await fs.childCount(of: folder(FakeCameraBackend.apple100)) == 2)
    }

    @Test func onlyImportAndDeleteAreOffered() async throws {
        let capabilities = fs.capabilities
        #expect(!capabilities.canWrite && !capabilities.canRename && !capabilities.canMoveNatively)
        #expect(capabilities.canDelete && capabilities.canThumbnail && capabilities.canReadPartially)
        #expect(!fs.isMock)

        let file = local.appending(path: "a.jpg")
        try Data([1]).write(to: file)
        let progress = TransferProgress()
        await #expect(throws: DeviceError.unsupportedOperation) {
            _ = try await self.fs.upload(from: file, size: 1, named: "a.jpg", into: self.root, modified: nil, progress: progress)
        }
        await #expect(throws: DeviceError.unsupportedOperation) {
            _ = try await self.fs.createFolder(named: "새 폴더", in: self.root)
        }
        await #expect(throws: DeviceError.unsupportedOperation) {
            _ = try await self.fs.rename(self.folder(FakeCameraBackend.photo), to: "b.heic")
        }
    }

    @Test func partialReadsAndThumbnailsGoToTheBackend() async throws {
        let bytes = try await fs.read(folder(FakeCameraBackend.video), offset: 10, length: 5)
        #expect(bytes == backend.content(FakeCameraBackend.video)?.subdata(in: 10..<15))
        #expect(try await fs.thumbnail(folder(FakeCameraBackend.photo)) == Data([0xFF, 0xD8]))
    }

    @Test func aLockedOrUntrustedDeviceReportsAccessDenied() async throws {
        backend.restricted = true
        await #expect(throws: DeviceError.accessDenied) {
            _ = try await self.fs.contents(of: self.root)
        }
    }

    // MARK: - Import / delete through the transfer queue

    @Test func importCopiesTheExactBytesInShortReads() async throws {
        let job = await run(.download(items: [try await ref(FakeCameraBackend.photo), try await ref(FakeCameraBackend.video)],
                                      generation: fs.generation, destination: local, deleteSourceAfter: false))
        #expect(job.state == .completed)
        #expect(try Data(contentsOf: local.appending(path: "IMG_0001.HEIC")) == backend.content(FakeCameraBackend.photo))
        #expect(try Data(contentsOf: local.appending(path: "IMG_0002.MOV")) == backend.content(FakeCameraBackend.video))
        #expect(backend.deleted.isEmpty)
    }

    @Test func importingAFolderBringsItsPhotos() async throws {
        let job = await run(.download(items: [try await ref(FakeCameraBackend.apple100, parentPath: ["DCIM"])],
                                      generation: fs.generation, destination: local, deleteSourceAfter: false))
        #expect(job.state == .completed)
        let names = try FileManager.default.contentsOfDirectory(atPath: local.appending(path: "100APPLE").path).sorted()
        #expect(names == ["IMG_0001.HEIC", "IMG_0002.MOV"])
    }

    @Test func moveToMacDeletesOnlyAfterTheCopy() async throws {
        let job = await run(.download(items: [try await ref(FakeCameraBackend.photo)],
                                      generation: fs.generation, destination: local, deleteSourceAfter: true))
        #expect(job.state == .completed)
        #expect(FileManager.default.fileExists(atPath: local.appending(path: "IMG_0001.HEIC").path))
        #expect(backend.deleted == [FakeCameraBackend.photo])
    }

    @Test func deleteRemovesPhotosFromTheDevice() async throws {
        let job = await run(.delete(items: [try await ref(FakeCameraBackend.video)], generation: fs.generation))
        #expect(job.state == .completed)
        #expect(backend.deleted == [FakeCameraBackend.video])
        #expect(try await fs.contents(of: folder(FakeCameraBackend.apple100)).map(\.name) == ["IMG_0001.HEIC"])
    }

    @Test func iOSFoldersAreNeverDeletedThemselves() async throws {
        // An empty folder is iOS's own: "deleting" it is a no-op, not an error.
        try await fs.delete(folder(FakeCameraBackend.emptyFolder))
        await #expect(throws: DeviceError.folderNotEmpty) {
            try await self.fs.delete(self.folder(FakeCameraBackend.dcim))
        }
        #expect(backend.deleted.isEmpty)
    }

    // MARK: - App model

    private func makeModel(apple: AppleDeviceManager) -> AppModel {
        let defaults = freshDefaults()
        defaults.set(false, forKey: AppSettings.Key.showDemoDevice)
        let broker = DeviceBroker(monitor: MockUSBMonitor(), backend: MockMTPBackend(), configuration: .fast)
        return AppModel(broker: broker, localization: LocalizationManager(defaults: defaults),
                        settings: AppSettings(defaults: defaults),
                        localAccess: LocalAccessManager(defaults: defaults, defaultFolder: local),
                        appleDevices: apple)
    }

    @Test func connectingAnIPhoneGuidesTrustThenOpensItsPhotos() async throws {
        let apple = AppleDeviceManager(storageName: { "사진 및 동영상" })
        let model = makeModel(apple: apple)
        await model.start(startBroker: false)

        apple.simulateAttach(deviceID, name: "테스트 iPhone")
        #expect(model.sidebarSelection == .device(deviceID))
        #expect(model.detailContent == .appleDeviceState(try #require(apple.record(for: deviceID))))

        apple.simulateState(deviceID, .needsTrust)
        if case .appleDeviceState(let record) = model.detailContent {
            #expect(record.state == .needsTrust)
        } else {
            Issue.record("expected the trust guide")
        }
        #expect(apple.fileSystem(for: deviceID) == nil, "nothing is browsable before trust")

        apple.simulateReady(deviceID, backend: backend)
        #expect(model.sidebarSelection == .storage(deviceID, ImageCaptureFileSystem.storageID))
        #expect(model.detailContent == .browser)
        #expect(model.selectedDeviceName == "테스트 iPhone")
        try await waitUntil { model.browser.phase == .loaded }
        #expect(model.browser.items.map(\.name) == ["DCIM"])
        #expect(model.browser.isShowingMock == false)
        #expect(model.canDeleteHere && !model.canWriteHere && !model.canRenameHere)
        if case .deviceConnected(let name) = model.notice?.kind {
            #expect(name == "테스트 iPhone")
        } else {
            Issue.record("expected a connected notice")
        }

        apple.simulateRemove(deviceID)
        #expect(model.sidebarSelection == nil)
        #expect(model.browser.fileSystem == nil)
        #expect(model.detailContent == .welcome)
        if case .deviceDisconnected = model.notice?.kind {} else {
            Issue.record("expected a disconnect notice")
        }
    }

    @Test func anIPhoneDoesNotTakeOverAnotherDevicesBrowser() async throws {
        let apple = AppleDeviceManager()
        let model = makeModel(apple: apple)
        await model.start(startBroker: false)
        let other = DeviceID("ios:OTHER")
        apple.simulateAttach(other, name: "iPad", isTablet: true)
        apple.simulateReady(other, backend: FakeCameraBackend())
        #expect(model.sidebarSelection == .storage(other, ImageCaptureFileSystem.storageID))

        apple.simulateAttach(deviceID, name: "iPhone")
        apple.simulateReady(deviceID, backend: backend)
        #expect(model.sidebarSelection == .storage(other, ImageCaptureFileSystem.storageID), "the user's current device stays open")
    }

    @Test func aFailedSessionIsShownWithItsDetail() async throws {
        let apple = AppleDeviceManager()
        let model = makeModel(apple: apple)
        await model.start(startBroker: false)
        apple.simulateAttach(deviceID, name: "iPhone")
        apple.simulateState(deviceID, .failed("com.apple.ImageCaptureCore -9912"))
        if case .connectionFailed = model.notice?.kind {} else {
            Issue.record("expected a failure notice")
        }
        if case .appleDeviceState(let record) = model.detailContent {
            #expect(record.state == .failed("com.apple.ImageCaptureCore -9912"))
        } else {
            Issue.record("expected the failure view")
        }
    }

    /// A running Image Capture browser makes ptpcamerad take Android phones
    /// too (D78): it runs only while an iPhone/iPad is on USB.
    @Test func imageCaptureRunsOnlyWhileAnAppleDeviceIsPluggedIn() async throws {
        let monitor = MockUSBMonitor()
        let defaults = freshDefaults()
        let apple = AppleDeviceManager()
        let model = AppModel(broker: DeviceBroker(monitor: monitor, backend: MockMTPBackend(), configuration: .fast),
                             localization: LocalizationManager(defaults: defaults), settings: AppSettings(defaults: defaults),
                             localAccess: LocalAccessManager(defaults: defaults, defaultFolder: local), appleDevices: apple)
        await model.start()
        #expect(!apple.wantsBrowsing, "nothing plugged in")

        monitor.send(.attached(.fixture(registryID: 1)))
        try await waitUntil { model.broker.devices.first?.state == .connected }
        #expect(!apple.wantsBrowsing, "an Android phone alone never starts Image Capture")

        monitor.send(.attached(.fixture(registryID: 2, vendorID: 0x05AC, productID: 0x12A8, serial: "IPHONE",
                                        product: "iPhone", interfaces: [.stillImageUnnamed])))
        try await waitUntil { apple.wantsBrowsing }

        monitor.send(.detached(registryID: 2))
        try await waitUntil { !apple.wantsBrowsing }
        #expect(model.broker.devices.first?.state == .connected, "the Android phone stays connected")
    }

    @Test func theTestManagerNeverStartsImageCapture() {
        let apple = AppleDeviceManager()
        apple.start()
        #expect(apple.records.isEmpty)
    }
}
