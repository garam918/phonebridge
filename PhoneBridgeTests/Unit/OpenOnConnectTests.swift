import Foundation
import ServiceManagement
import Testing
@testable import PhoneBridge

/// "휴대전화를 연결하면 PhoneBridge 열기" (D73): when the launcher opens the app,
/// and how the setting talks to macOS's login items.
@Suite("Open on connect")
struct OpenOnConnectTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func plugginInAPhoneOpensOnce() {
        var detector = PhoneAttachDetector(startedAt: start)
        let phone = USBDeviceSnapshot.fixture(registryID: 10, interfaces: [.androidMTP])
        do {
            let opened = detector.handle(.attached(phone), now: at(10))
            #expect(opened)
        }
        // The same snapshot again (interfaces settling) does not reopen.
        do {
            let opened = detector.handle(.attached(phone), now: at(11))
            #expect(!opened)
        }
    }

    @Test func phonesAlreadyConnectedAtStartAreLeftAlone() {
        var detector = PhoneAttachDetector(startedAt: start)
        let phone = USBDeviceSnapshot.fixture(registryID: 10, interfaces: [.androidMTP])
        do {
            let opened = detector.handle(.attached(phone), now: at(0.5))
            #expect(!opened, "present at login / when the setting was turned on")
        }
        do {
            let opened = detector.handle(.attached(phone), now: at(30))
            #expect(!opened)
        }
    }

    @Test func switchingUSBModeIsNotANewConnection() {
        var detector = PhoneAttachDetector(startedAt: start)
        // Plugged in charging-only (ADB/vendor interfaces only), then switched to File transfer:
        // the phone disappears and comes back with a new registry entry and product id.
        let charging = USBDeviceSnapshot.fixture(registryID: 10, productID: 0x6866, interfaces: [.androidADB])
        let fileTransfer = USBDeviceSnapshot.fixture(registryID: 11, productID: 0x6860, interfaces: [.androidMTP, .androidADB])
        do {
            let opened = detector.handle(.attached(charging), now: at(10))
            #expect(opened, "charging-only still opens: the app explains what to do")
        }
        do {
            let opened = detector.handle(.detached(registryID: 10), now: at(15))
            #expect(!opened)
        }
        do {
            let opened = detector.handle(.attached(fileTransfer), now: at(16))
            #expect(!opened)
        }
    }

    @Test func replugginInLaterOpensAgain() {
        var detector = PhoneAttachDetector(startedAt: start)
        let phone = USBDeviceSnapshot.fixture(registryID: 10, interfaces: [.androidMTP])
        do {
            let opened = detector.handle(.attached(phone), now: at(10))
            #expect(opened)
        }
        _ = detector.handle(.detached(registryID: 10), now: at(60))
        let again = USBDeviceSnapshot.fixture(registryID: 12, interfaces: [.androidMTP])
        do {
            let opened = detector.handle(.attached(again), now: at(120))
            #expect(opened)
        }
    }

    @Test func plugginInAnIPhoneOrIPadOpensToo() {
        var detector = PhoneAttachDetector(startedAt: start)
        let iphone = USBDeviceSnapshot.fixture(registryID: 20, vendorID: 0x05AC, productID: 0x12A8, serial: "IPHONE",
                                               product: "iPhone", interfaces: [.stillImageUnnamed])
        let ipad = USBDeviceSnapshot.fixture(registryID: 24, vendorID: 0x05AC, productID: 0x12AB, serial: "IPAD",
                                             product: "iPad", interfaces: [.stillImageUnnamed])
        for device in [iphone, ipad] {
            do {
                let opened = detector.handle(.attached(device), now: at(10))
                #expect(opened, "\(device.displayName)")
            }
        }
        do {
            let opened = detector.handle(.attached(iphone), now: at(11))
            #expect(!opened, "once per connection")
        }
    }

    @Test func otherUSBDevicesNeverOpenTheApp() {
        var detector = PhoneAttachDetector(startedAt: start)
        let keyboard = USBDeviceSnapshot.fixture(registryID: 21, vendorID: 0x04E8, productID: 0x7001, serial: "KB",
                                                 product: "Keyboard", interfaces: [.hid])
        let drive = USBDeviceSnapshot.fixture(registryID: 22, vendorID: 0x04E8, productID: 0x61F5, serial: "T7",
                                              product: "Portable SSD", interfaces: [.massStorage])
        let camera = USBDeviceSnapshot.fixture(registryID: 23, vendorID: 0x04A9, productID: 0x3200, serial: "CAM",
                                               product: "Camera", interfaces: [.stillImageUnnamed])
        for device in [keyboard, drive, camera] {
            do {
                let opened = detector.handle(.attached(device), now: at(10))
                #expect(!opened, "\(device.displayName)")
            }
        }
    }

    @Test func aPhoneStillEnumeratingWaitsForItsInterfaces() {
        var detector = PhoneAttachDetector(startedAt: start)
        let early = USBDeviceSnapshot.fixture(registryID: 30, interfaces: [], settled: false)
        let settled = USBDeviceSnapshot.fixture(registryID: 30, interfaces: [.androidMTP])
        do {
            let opened = detector.handle(.attached(early), now: at(10))
            #expect(!opened)
        }
        do {
            let opened = detector.handle(.attached(settled), now: at(10.4))
            #expect(opened)
        }
    }

    // MARK: - Setting

    final class FakeLoginItem: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var statusAfterRegister: SMAppService.Status = .enabled
        var failRegister = false
        private(set) var calls: [String] = []

        func register() throws {
            calls.append("register")
            if failRegister { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
            status = statusAfterRegister
        }

        func unregister() throws {
            calls.append("unregister")
            status = .notRegistered
        }
    }

    @MainActor @Test func offByDefault() {
        let service = FakeLoginItem()
        let setting = LaunchOnConnectSetting(service: service, openSettings: {})
        setting.refresh()
        #expect(setting.state == .off && !setting.isOn)
        #expect(service.calls.isEmpty, "nothing is registered until the user turns it on")
    }

    @MainActor @Test func turningOnAndOffRegistersTheLoginItem() {
        let service = FakeLoginItem()
        let setting = LaunchOnConnectSetting(service: service, openSettings: {})
        setting.setEnabled(true)
        #expect(setting.state == .on && setting.isOn)
        setting.setEnabled(false)
        #expect(setting.state == .off)
        #expect(service.calls == ["register", "unregister"])
    }

    @MainActor @Test func approvalInSystemSettingsIsShown() {
        let service = FakeLoginItem()
        service.statusAfterRegister = .requiresApproval
        var opened = false
        let setting = LaunchOnConnectSetting(service: service, openSettings: { opened = true })
        setting.setEnabled(true)
        #expect(setting.state == .needsApproval && setting.isOn)
        setting.openLoginItemsSettings()
        #expect(opened)
    }

    @MainActor @Test func aFailedRegistrationIsReportedNotHidden() {
        let service = FakeLoginItem()
        service.failRegister = true
        let setting = LaunchOnConnectSetting(service: service, openSettings: {})
        setting.setEnabled(true)
        #expect(setting.state == .unavailable("SMAppServiceErrorDomain 1"))
        #expect(!setting.isOn)
    }

    @MainActor @Test func theRealLoginItemIsNotRegisteredInTests() {
        // The app's own launcher identifier; the test host never turned it on.
        #expect(LaunchOnConnectSetting.launcherIdentifier.hasSuffix(".Launcher"))
        let setting = LaunchOnConnectSetting()
        setting.refresh()
        #expect(setting.state == .off)
    }
}
