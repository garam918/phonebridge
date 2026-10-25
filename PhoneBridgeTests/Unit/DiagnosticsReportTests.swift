import Foundation
import OSLog
import Testing
@testable import PhoneBridge

@MainActor
@Suite("Diagnostics export")
struct DiagnosticsReportTests {
    let monitor = MockUSBMonitor()
    let backend = MockMTPBackend()

    @Test func summaryNamesModelsButNotSerialsOrPersonalNames() async throws {
        let defaults = freshDefaults()
        defaults.set(false, forKey: AppSettings.Key.showDemoDevice)
        let broker = DeviceBroker(monitor: monitor, backend: backend, configuration: .fast)
        let model = AppModel(broker: broker, localization: LocalizationManager(defaults: defaults),
                             settings: AppSettings(defaults: defaults),
                             localAccess: LocalAccessManager(defaults: defaults, defaultFolder: FileManager.default.temporaryDirectory))
        await model.start()
        monitor.send(.attached(.fixture(serial: "R5CY1234ABC")))
        try await waitUntil { model.broker.devices.first?.state == .connected }

        let text = DiagnosticsReport.summary(model: model)
        #expect(text.contains("Pixel 8"))
        #expect(text.contains("usb 18d1:4ee1"))
        #expect(text.contains("state connected"))
        #expect(!text.contains("R5CY1234ABC"), "serial numbers appear only as a hash")
        #expect(text.contains("#\(DiagnosticsReport.shortHash(USBDeviceSnapshot.fixture(serial: "R5CY1234ABC").logicalID.rawValue))"))
    }

    @Test func logLinesComeFromThisProcessOnly() async {
        let marker = "diagnostics-test-\(UUID().uuidString.prefix(8))"
        Log.app.info("\(marker, privacy: .public) public marker")
        let lines = await Task.detached { DiagnosticsReport.logLines() }.value
        #expect(lines.contains { $0.contains(marker) && $0.contains("[app]") })
    }

    @Test func extensionStatusIsKeptShortAndWithoutUserPaths() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ExtensionStatus-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = ExtensionStatusRecorder(url: url, processID: 101, isAlive: { _ in true })
        recorder.record("mounted", "read-only", mountedChange: 1)
        recorder.record("load-failed", "61 connect /Users/someone/Library/Group Containers/x/finder-broker.sock: Connection refused")
        for index in 0..<150 { recorder.record("write-failed", "5 error.usb \(index)") }

        let saved = try #require(ExtensionStatus.read(from: url))
        #expect(saved.events.count == ExtensionStatus.eventLimit)
        #expect(saved.mountedVolumes == 1)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("someone"))
        recorder.record("unmounted", mountedChange: -1)
        #expect(ExtensionStatus.read(from: url)?.mountedVolumes == 0)
    }

    @Test func severalExtensionProcessesShareTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ExtensionStatus-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ExtensionStatusRecorder(url: url, processID: 201, isAlive: { _ in true })
        let second = ExtensionStatusRecorder(url: url, processID: 202, isAlive: { _ in true })
        first.record("mounted", mountedChange: 1)
        second.record("mounted", mountedChange: 1)
        first.record("loaded")
        let saved = try #require(ExtensionStatus.read(from: url))
        #expect(saved.events.map(\.kind) == ["mounted", "mounted", "loaded"], "nobody overwrites the other's events")
        #expect(saved.mountedVolumes == 2)

        // Process 201 ends without unmounting (crash): its volume is no longer counted.
        let third = ExtensionStatusRecorder(url: url, processID: 203, isAlive: { $0 != 201 })
        third.record("loaded")
        #expect(ExtensionStatus.read(from: url)?.mountedVolumes == 1)
    }

    @Test func summaryIncludesTheExtensionSide() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ExtensionStatus-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        ExtensionStatusRecorder(url: url).record("loaded", "writable")
        let defaults = freshDefaults()
        let model = AppModel(broker: DeviceBroker(monitor: monitor, backend: backend), localization: LocalizationManager(defaults: defaults),
                             settings: AppSettings(defaults: defaults))
        let text = DiagnosticsReport.summary(model: model, extensionStatusURL: url)
        #expect(text.contains("[finder extension]"))
        #expect(text.contains("loaded: writable"))
        #expect(DiagnosticsReport.summary(model: model, extensionStatusURL: nil).contains("no status file"))
    }
}
