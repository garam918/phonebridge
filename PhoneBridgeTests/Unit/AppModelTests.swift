import Foundation
import Testing
@testable import PhoneBridge

/// UI-state recovery around connect / disconnect, without real hardware.
@MainActor
@Suite("AppModel connection recovery (mock)")
struct AppModelTests {
    let monitor = MockUSBMonitor()
    let backend = MockMTPBackend()

    private func makeModel(showDemo: Bool = false) -> AppModel {
        let defaults = freshDefaults()
        defaults.set(showDemo, forKey: AppSettings.Key.showDemoDevice)
        let broker = DeviceBroker(monitor: monitor, backend: backend, configuration: .fast)
        return AppModel(broker: broker, localization: LocalizationManager(defaults: defaults),
                        settings: AppSettings(defaults: defaults),
                        localAccess: LocalAccessManager(defaults: defaults, defaultFolder: FileManager.default.temporaryDirectory))
    }

    private var pixelID: DeviceID { USBDeviceSnapshot.fixture().logicalID }

    @Test func connectedDeviceIsSelectedAndBrowsed() async throws {
        let model = makeModel()
        await model.start()
        monitor.send(.attached(.fixture()))

        try await waitUntil { model.browser.phase == .loaded }
        #expect(model.sidebarSelection == .storage(pixelID, 0x0001_0001))
        #expect(model.detailContent == .browser)
        #expect(model.browser.items.map(\.name) == ["DCIM", "Download", "notes.txt"])
        #expect(model.browser.isShowingMock == false)
    }

    @Test func demoSelectionYieldsToFirstRealDevice() async throws {
        let model = makeModel(showDemo: true)
        await model.start()
        #expect(model.isDemoSelected)
        try await waitUntil { model.browser.phase == .loaded }
        #expect(model.browser.isShowingMock)

        monitor.send(.attached(.fixture()))
        try await waitUntil { model.browser.deviceID == pixelID && model.browser.phase == .loaded }
        #expect(model.browser.isShowingMock == false)
    }

    @Test func unplugWhileBrowsingRecoversWithoutErrors() async throws {
        let model = makeModel()
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { model.browser.phase == .loaded }

        let dcim = try #require(model.browser.items.first { $0.name == "DCIM" })
        await model.browser.enter(dcim)
        #expect(model.browser.path.map(\.name) == ["내부 저장공간", "DCIM"])

        monitor.send(.detached(registryID: 1))
        try await waitUntil { model.selectedRecord?.state == .reconnecting }
        // Browser is emptied instead of showing a failed listing.
        #expect(model.browser.fileSystem == nil)
        #expect(model.browser.items.isEmpty)
        #expect(model.browser.phase == .idle)
        if case .deviceState(let record) = model.detailContent {
            #expect(record.state == .reconnecting)
        } else {
            Issue.record("expected the device state view while reconnecting")
        }

        // Grace period ends: selection is cleared, welcome screen returns.
        try await waitUntil { model.broker.devices.isEmpty }
        #expect(model.sidebarSelection == nil)
        #expect(model.detailContent == .welcome)
        if case .deviceDisconnected = model.notice?.kind {} else {
            Issue.record("expected a disconnect notice, got \(String(describing: model.notice))")
        }
    }

    @Test func replugReturnsToStorageRootOfNewSession() async throws {
        let model = makeModel()
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { model.browser.phase == .loaded }
        let dcim = try #require(model.browser.items.first { $0.name == "DCIM" })
        await model.browser.enter(dcim)
        let oldGeneration = model.browser.generation

        monitor.send(.detached(registryID: 1))
        try await waitUntil { model.selectedRecord?.state == .reconnecting }
        monitor.send(.attached(.fixture(registryID: 2)))

        try await waitUntil { model.browser.phase == .loaded && model.browser.generation != oldGeneration }
        #expect(model.browser.path.count == 1, "object handles do not survive a new session")
        #expect(model.sidebarSelection?.deviceID == pixelID)
    }

    @Test func failedConnectionShowsStateViewAndNotice() async throws {
        let model = makeModel()
        backend.configure { $0.preflight = .busy }
        await model.start()
        monitor.send(.attached(.fixture()))
        try await waitUntil { model.broker.record(for: pixelID) != nil }
        model.sidebarSelection = .device(pixelID)

        try await waitUntil {
            if case .deviceState(let record) = model.detailContent, case .failed(.deviceBusy) = record.state { return true }
            return false
        }
        #expect(model.notice?.kind == .connectionFailed("Pixel 8"))
    }
}
