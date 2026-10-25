import Foundation
import Testing
@testable import PhoneBridge

/// Runs the real native stack on this Mac (inside the app sandbox, because
/// tests are hosted by PhoneBridge.app). No Android device is required: these
/// only prove libmtp/libusb/IOKit are linked and usable from the sandbox.
@Suite("Host environment (real libmtp / libusb / IOKit)")
struct HostEnvironmentTests {
    @Test func libmtpIsLinked() {
        #expect(LibMTPBackend.libmtpVersion == "1.1.23")
    }

    @Test func libusbCanEnumerateFromSandbox() {
        let count = LibMTPBackend.visibleUSBDeviceCount()
        #expect(count >= 0, "libusb error \(count): check the com.apple.security.device.usb entitlement")
    }

    @Test func preflightOnAbsentDeviceReportsDisconnected() {
        let result = LibMTPBackend().preflight(MTPTarget(bus: 250, address: 250, vendorID: 0x18D1, productID: 0x4EE1))
        #expect(result == .failed(.disconnected))
    }

    @Test func openOnAbsentDeviceThrowsSwiftError() {
        #expect(throws: DeviceError.self) {
            _ = try LibMTPBackend().open(MTPTarget(bus: 250, address: 250, vendorID: 0x18D1, productID: 0x4EE1))
        }
    }

    @Test func ioKitMonitorReportsAttachedDevices() async throws {
        let monitor = IOKitUSBMonitor(settleDelay: 0.2)
        monitor.start()
        defer { monitor.stop() }

        let collector = Task {
            var snapshots: [USBDeviceSnapshot] = []
            for await event in monitor.events {
                if case .attached(let snapshot) = event { snapshots.append(snapshot) }
            }
            return snapshots
        }
        try await Task.sleep(for: .seconds(1))
        collector.cancel()
        let snapshots = await collector.value
        let libusbCount = LibMTPBackend.visibleUSBDeviceCount()

        if libusbCount > 0 {
            #expect(!snapshots.isEmpty, "IOKit reported nothing although libusb sees \(libusbCount) device(s)")
        }
        for snapshot in snapshots {
            #expect(snapshot.registryID != 0)
            print("[host] USB \(snapshot.idPairDescription) \(snapshot.displayName) bus=\(snapshot.busNumber) addr=\(snapshot.address) "
                  + "interfaces=\(snapshot.interfaces.count) → \(USBDeviceClassifier.classify(snapshot))")
        }
    }
}
