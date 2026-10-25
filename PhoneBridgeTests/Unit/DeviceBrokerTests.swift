import Foundation
import Testing
@testable import PhoneBridge

/// Connection state machine, driven by a mock USB monitor and a mock MTP
/// backend. No real hardware involved.
@MainActor
@Suite("DeviceBroker (mock USB + mock MTP)")
struct DeviceBrokerTests {
    let monitor = MockUSBMonitor()
    let backend = MockMTPBackend()

    private func makeBroker(_ configuration: DeviceBroker.Configuration = .fast) -> DeviceBroker {
        let broker = DeviceBroker(monitor: monitor, backend: backend, configuration: configuration)
        broker.start()
        return broker
    }

    private var pixelID: DeviceID { USBDeviceSnapshot.fixture().logicalID }

    @Test func mtpDeviceConnectsAndLoadsStorages() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture()))

        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let record = try #require(broker.record(for: pixelID))
        #expect(record.storages.map(\.id) == [0x0001_0001])
        #expect(record.info?.model == "Pixel 8")
        #expect(record.displayName == "Google Pixel 8")
        #expect(record.state.isUSBPresent && record.state.isMTPReady)
        #expect(broker.fileSystem(for: pixelID) != nil)
    }

    @Test func unrelatedUSBDevicesAreIgnored() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture(registryID: 10, vendorID: 0x1EA7, productID: 0x0064, serial: nil,
                                        product: "2.4G Mouse", interfaces: [.hid])))
        monitor.send(.attached(.fixture(registryID: 11, vendorID: 0x04E8, productID: 0x4001, serial: "T7",
                                        product: "Portable SSD T7", interfaces: [.massStorage])))
        monitor.send(.attached(.fixture(registryID: 12, vendorID: 0x0BDA, productID: 0x5411, serial: nil,
                                        product: "USB2.1 Hub", interfaces: [.hub])))
        try await Task.sleep(for: .milliseconds(80))
        #expect(broker.devices.isEmpty)
        #expect(backend.stats.total == 0)
    }

    @Test func chargingOnlyModeWaitsThenConnectsAfterModeSwitch() async throws {
        let broker = makeBroker()
        // Charging only + USB debugging: only the ADB interface is present.
        monitor.send(.attached(.fixture(registryID: 1, productID: 0x4EE7, interfaces: [.androidADB])))
        try await waitUntil { broker.record(for: pixelID)?.state == .waitingForMTP(.fileTransferModeRequired) }
        #expect(broker.record(for: pixelID)?.state.isUSBPresent == true)
        #expect(broker.record(for: pixelID)?.state.isMTPReady == false)
        #expect(backend.stats.open == 0)

        // User picks "File transfer": Android re-enumerates with a new PID, same serial.
        monitor.send(.detached(registryID: 1))
        try await waitUntil { broker.record(for: pixelID)?.state == .reconnecting }
        monitor.send(.attached(.fixture(registryID: 2, productID: 0x4EE1, interfaces: [.androidMTP, .androidADB])))

        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        #expect(broker.devices.count == 1)
    }

    @Test func ptpModeAsksForFileTransfer() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture(interfaces: [.androidPTP])))
        try await waitUntil { broker.record(for: pixelID)?.state == .waitingForMTP(.ptpModeSelected) }
        #expect(backend.stats.open == 0)
    }

    @Test func interfacesStillEnumeratingStaysUSBDetected() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture(interfaces: [], settled: false)))
        try await waitUntil { broker.record(for: pixelID)?.state == .usbDetected }
        monitor.send(.attached(.fixture(interfaces: [], settled: true)))
        try await waitUntil { broker.record(for: pixelID)?.state == .waitingForMTP(.fileTransferModeRequired) }
    }

    @Test func busyInterfaceReportsOwnerWithoutOpeningSession() async throws {
        let broker = makeBroker()
        backend.configure { $0.preflight = .busy }
        monitor.setOwner("ptpcamerad (pid 512)", registryID: 1)
        monitor.send(.attached(.fixture()))

        try await waitUntil { broker.record(for: pixelID)?.state == .failed(.deviceBusy(owner: "ptpcamerad (pid 512)")) }
        #expect(backend.stats.open == 0, "libmtp must not be asked to open a claimed device")
        #expect(broker.record(for: pixelID)?.state.canRetry == true)

        // The user quits the other program and retries.
        backend.configure { $0.preflight = .available }
        broker.retry(pixelID)
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
    }

    /// Real Samsung behaviour: right after plug-in libusb briefly cannot see
    /// the device at the address IOKit reported.
    @Test func transientNoDeviceRightAfterPlugInIsRetried() async throws {
        let broker = makeBroker()
        backend.configure { $0.transientPreflightFailures = 1 }
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        #expect(backend.stats.open == 1)
    }

    @Test func persistentNoDeviceStillFailsAfterBoundedRetries() async throws {
        let broker = makeBroker()
        backend.configure { $0.transientPreflightFailures = 10 }
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .failed(.disconnected) }
        #expect(backend.stats.open == 0)
    }

    @Test func lockedDeviceWaitsForStorageThenConnects() async throws {
        let broker = makeBroker()
        backend.configure { $0.lockedPolls = 4 }
        var sawLocked = false
        broker.onChange = { change in
            if change.record?.state == .waitingForMTP(.deviceLocked) { sawLocked = true }
        }
        monitor.send(.attached(.fixture()))

        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        #expect(sawLocked)
        #expect(backend.stats.open == 1, "unlocking must not require a new session")
    }

    @Test func openFailureRetriesOnceThenFailsAndManualRetryRecovers() async throws {
        let broker = makeBroker()
        backend.configure { $0.openFailures = 2 }
        monitor.send(.attached(.fixture()))

        try await waitUntil {
            if case .failed(.sessionOpenFailed) = broker.record(for: pixelID)?.state { return true }
            return false
        }
        #expect(backend.stats.open == 2, "one automatic retry")

        broker.retry(pixelID)
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
    }

    @Test func unplugGoesReconnectingThenDisconnectedAndClosesSession() async throws {
        let broker = makeBroker()
        var states: [ConnectionState?] = []
        broker.onChange = { change in states.append(change.record?.state) }
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }

        monitor.send(.detached(registryID: 1))
        try await waitUntil { broker.record(for: pixelID)?.state == .reconnecting }
        #expect(broker.record(for: pixelID)?.storages.isEmpty == true)
        #expect(broker.fileSystem(for: pixelID) == nil)
        try await waitUntil { backend.stats.close == 1 }

        try await waitUntil { broker.devices.isEmpty }
        #expect(states.contains(.disconnected))
        #expect(states.last == .some(nil), "record removed after the grace period")
    }

    @Test func replugWithinGracePeriodStartsNewSession() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let firstGeneration = try #require(broker.record(for: pixelID)?.generation)

        monitor.send(.detached(registryID: 1))
        try await waitUntil { broker.record(for: pixelID)?.state == .reconnecting }
        monitor.send(.attached(.fixture(registryID: 7, address: 9)))

        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let record = try #require(broker.record(for: pixelID))
        #expect(record.generation > firstGeneration)
        #expect(record.usb.address == 9)
        // The grace timer must have been cancelled: the device stays.
        try await Task.sleep(for: .milliseconds(400))
        #expect(broker.record(for: pixelID)?.state == .connected)
    }

    @Test func interfaceChurnDuringSessionDoesNotReconnect() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }

        monitor.send(.attached(.fixture(interfaces: [.androidMTP, .androidADB])))
        try await Task.sleep(for: .milliseconds(60))
        #expect(broker.record(for: pixelID)?.state == .connected)
        #expect(backend.stats.open == 1)
    }

    @Test func iPhoneIsUnsupportedAndDroppedImmediatelyOnUnplug() async throws {
        let broker = makeBroker()
        let iphone = USBDeviceSnapshot.fixture(registryID: 3, vendorID: 0x05AC, productID: 0x12A8, serial: "IPHONE",
                                               product: "iPhone", interfaces: [.stillImageUnnamed])
        monitor.send(.attached(iphone))
        try await waitUntil { broker.record(for: iphone.logicalID)?.state == .unsupported(.appleDevice) }
        monitor.send(.detached(registryID: 3))
        try await waitUntil { broker.devices.isEmpty }
        #expect(backend.stats.total == 0)
    }

    @Test func mtpCallsAreSerializedAndNeverOnMainThread() async throws {
        let broker = makeBroker()
        backend.configure { $0.callDelay = 0.01 }
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let fileSystem = try #require(broker.fileSystem(for: pixelID))

        let folders: [UInt32] = [FileItemID.rootObjectID, MockMTPBackend.dcimID, MockMTPBackend.cameraID, MockMTPBackend.downloadID]
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<12 {
                let folder = FileItemID(deviceID: pixelID, storageID: 0x0001_0001, objectID: folders[index % folders.count])
                group.addTask { try await fileSystem.contents(of: folder).count }
            }
            for try await _ in group {}
        }
        let stats = backend.stats
        #expect(stats.maxConcurrent == 1, "per-device MTP operations must be serialized")
        #expect(stats.mainThread == 0, "blocking MTP I/O must not run on the main thread")
        #expect(stats.total >= 15)
    }

    @Test func staleFileSystemFailsSafelyAfterUnplug() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let fileSystem = try #require(broker.fileSystem(for: pixelID))

        monitor.send(.detached(registryID: 1))
        try await waitUntil { backend.stats.close == 1 }
        await #expect(throws: DeviceError.disconnected) {
            _ = try await fileSystem.contents(of: .root(deviceID: pixelID, storageID: 0x0001_0001))
        }
    }

    @Test func shutdownClosesOpenSessions() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        await broker.shutdown()
        #expect(backend.stats.close == 1)
    }

    // MARK: Safely disconnect

    @Test func safelyDisconnectClosesTheSessionUntilReconnect() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        await broker.safelyDisconnect(pixelID)
        #expect(broker.record(for: pixelID)?.state == .safelyDisconnected)
        #expect(broker.fileSystem(for: pixelID) == nil)
        try await waitUntil { backend.stats.close == 1 }

        // Interface notifications of the same plug-in do not reconnect.
        monitor.send(.attached(.fixture(interfaces: [.androidMTP, .androidADB])))
        try await Task.sleep(for: .milliseconds(80))
        #expect(broker.record(for: pixelID)?.state == .safelyDisconnected)
        #expect(backend.stats.open == 1)

        broker.retry(pixelID)
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        #expect(backend.stats.open == 2)
    }

    @Test func pluggingInAgainReconnectsAfterASafeDisconnect() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        await broker.safelyDisconnect(pixelID)
        monitor.send(.detached(registryID: 1))
        monitor.send(.attached(.fixture(registryID: 9, address: 4)))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
    }

    // MARK: Chunked uploads (review 2026-10-22: browsing during an upload)

    private func bigFile(_ size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pb-chunk-\(UUID().uuidString)")
        var data = Data(count: size)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, size) }
        try data.write(to: url)
        return url
    }

    @Test func largeUploadsGoInPiecesAndLetListingsThrough() async throws {
        let broker = makeBroker()
        backend.configure {
            $0.capabilities = [.rename, .editObjects, .partialSend]
            $0.callDelay = 0.03
        }
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let fileSystem = try #require(broker.fileSystem(for: pixelID))
        #expect(fileSystem.capabilities.canUploadInChunks)
        let size = Int(MTPDeviceFileSystem.chunkedUploadThreshold) + 9 << 20
        let source = try bigFile(size)
        defer { try? FileManager.default.removeItem(at: source) }
        let download = FileItemID(deviceID: pixelID, storageID: 0x0001_0001, objectID: MockMTPBackend.downloadID)

        let upload = Task { try await fileSystem.upload(from: source, size: UInt64(size), named: "video.mp4", into: download,
                                                        modified: nil, progress: TransferProgress()) }
        try await waitUntil { self.backend.callTrace.contains("partial") }
        _ = try await fileSystem.contents(of: download)
        let item = try await upload.value

        let steps = backend.callTrace.filter { ["list", "partial", "begin", "end"].contains($0) }
        let lastPartial = try #require(steps.lastIndex(of: "partial"))
        #expect(steps.lastIndex(of: "list").map { $0 < lastPartial } == true, "the listing ran between pieces: \(steps)")
        #expect(steps.filter { $0 == "partial" }.count == 3, "16 + 16 + 9 MiB")
        #expect(steps.suffix(1) == ["end"] || steps.last == "list")
        #expect(item.size == UInt64(size))
        #expect(backend.content(of: item.id.objectID) == (try Data(contentsOf: source)))
    }

    @Test func smallUploadsAndDevicesWithoutEditExtensionUseOneTransfer() async throws {
        let broker = makeBroker()
        backend.configure { $0.capabilities = [.rename] }
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let fileSystem = try #require(broker.fileSystem(for: pixelID))
        #expect(!fileSystem.capabilities.canUploadInChunks)
        let size = Int(MTPDeviceFileSystem.chunkedUploadThreshold) + 1
        let source = try bigFile(size)
        defer { try? FileManager.default.removeItem(at: source) }
        let download = FileItemID(deviceID: pixelID, storageID: 0x0001_0001, objectID: MockMTPBackend.downloadID)
        let item = try await fileSystem.upload(from: source, size: UInt64(size), named: "a.bin", into: download, modified: nil,
                                               progress: TransferProgress())
        #expect(item.size == UInt64(size))
        #expect(!backend.callTrace.contains("partial"))
    }

    @Test func failedPieceEndsTheEditAndReportsTheError() async throws {
        let broker = makeBroker()
        backend.configure {
            $0.capabilities = [.rename, .editObjects, .partialSend]
            $0.failPartialSend = 2
        }
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let fileSystem = try #require(broker.fileSystem(for: pixelID))
        let size = Int(MTPDeviceFileSystem.chunkedUploadThreshold) + 1
        let source = try bigFile(size)
        defer { try? FileManager.default.removeItem(at: source) }
        let download = FileItemID(deviceID: pixelID, storageID: 0x0001_0001, objectID: MockMTPBackend.downloadID)
        await #expect(throws: DeviceError.disconnected) {
            _ = try await fileSystem.upload(from: source, size: UInt64(size), named: ".phonebridge-x.part", into: download,
                                            modified: nil, progress: TransferProgress())
        }
        #expect(backend.callTrace.last == "end", "the edit is closed even after a failure")
        #expect(backend.object(named: ".phonebridge-x.part")?.size == 16 << 20, "partial object left for the caller to remove")
    }

    // MARK: Chunked downloads (browsing while a large file comes to the Mac)

    /// Uploads `size` random bytes (one transfer: no edit extension) to the device.
    private func deviceFile(_ size: Int, broker: DeviceBroker) async throws -> (any DeviceFileSystem, FileItem, Data) {
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let fileSystem = try #require(broker.fileSystem(for: pixelID))
        let source = try bigFile(size)
        defer { try? FileManager.default.removeItem(at: source) }
        let folder = FileItemID(deviceID: pixelID, storageID: 0x0001_0001, objectID: MockMTPBackend.downloadID)
        let item = try await fileSystem.upload(from: source, size: UInt64(size), named: "movie.mp4", into: folder, modified: nil,
                                               progress: TransferProgress())
        return (fileSystem, item, try Data(contentsOf: source))
    }

    @Test func largeDownloadsGoInPiecesAndLetListingsThrough() async throws {
        let broker = makeBroker()
        backend.configure { $0.capabilities = [.rename, .partialGet] }
        let size = Int(MTPDeviceFileSystem.chunkedDownloadThreshold) + 9 << 20
        let (fileSystem, item, expected) = try await deviceFile(size, broker: broker)
        backend.configure { $0.callDelay = 0.03 }
        let target = FileManager.default.temporaryDirectory.appending(path: "pb-chunk-dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }

        let progress = TransferProgress()
        let download = Task { try await fileSystem.download(item.id, to: target, progress: progress) }
        try await waitUntil { self.backend.callTrace.contains("read") }
        _ = try await fileSystem.contents(of: FileItemID(deviceID: pixelID, storageID: 0x0001_0001, objectID: MockMTPBackend.downloadID))
        try await download.value

        let steps = backend.callTrace.filter { ["list", "read"].contains($0) }
        let lastRead = try #require(steps.lastIndex(of: "read"))
        #expect(steps.lastIndex(of: "list").map { $0 < lastRead } == true, "the listing ran between pieces: \(steps)")
        #expect(steps.filter { $0 == "read" }.count == 3, "16 + 16 + 9 MiB")
        #expect(try Data(contentsOf: target) == expected)
        #expect(progress.completed == UInt64(size))
        #expect(backend.transferCounts.fullDownloads == 0)
    }

    @Test func failedPieceFallsBackToOneDownload() async throws {
        let broker = makeBroker()
        backend.configure { $0.capabilities = [.rename, .partialGet] }
        let size = Int(MTPDeviceFileSystem.chunkedDownloadThreshold) + 1
        let (fileSystem, item, expected) = try await deviceFile(size, broker: broker)
        backend.configure { $0.failPartialRead = 2 }
        let target = FileManager.default.temporaryDirectory.appending(path: "pb-chunk-dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }

        try await fileSystem.download(item.id, to: target, progress: TransferProgress())
        #expect(try Data(contentsOf: target) == expected, "restarted from the beginning, nothing doubled")
        #expect(backend.transferCounts.fullDownloads == 1)
    }

    @Test func smallDownloadsAndDevicesWithoutPartialReadUseOneTransfer() async throws {
        let broker = makeBroker()
        backend.configure { $0.capabilities = [.rename] }
        let size = Int(MTPDeviceFileSystem.chunkedDownloadThreshold) + 1
        let (fileSystem, item, expected) = try await deviceFile(size, broker: broker)
        let target = FileManager.default.temporaryDirectory.appending(path: "pb-chunk-dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }
        try await fileSystem.download(item.id, to: target, progress: TransferProgress())
        #expect(try Data(contentsOf: target) == expected)
        #expect(!backend.callTrace.contains("read"))
    }

    @Test func listingErrorsAreSwiftErrors() async throws {
        let broker = makeBroker()
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: pixelID)?.state == .connected }
        let fileSystem = try #require(broker.fileSystem(for: pixelID))
        await #expect(throws: DeviceError.objectNotFound) {
            _ = try await fileSystem.contents(of: FileItemID(deviceID: pixelID, storageID: 0x0001_0001, objectID: 0xDEAD))
        }
    }
}
