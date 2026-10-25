import Foundation
import Testing
@testable import PhoneBridge

@Suite("USBDeviceClassifier")
struct USBDeviceClassifierTests {
    @Test func androidMTPInterfaceIsCandidate() {
        #expect(USBDeviceClassifier.classify(.fixture(interfaces: [.androidMTP])) == .mtpCandidate)
        #expect(USBDeviceClassifier.classify(.fixture(interfaces: [.androidMTP, .androidADB])) == .mtpCandidate)
    }

    @Test func mtpNamedInterfaceWinsEvenForUnknownVendor() {
        let tablet = USBDeviceSnapshot.fixture(vendorID: 0x1234, interfaces: [.androidMTP])
        #expect(USBDeviceClassifier.classify(tablet) == .mtpCandidate)
    }

    @Test func olderSamsungStillImageWithoutNameIsCandidate() {
        let galaxy = USBDeviceSnapshot.fixture(vendorID: 0x04E8, productID: 0x6860, interfaces: [.stillImageUnnamed])
        #expect(USBDeviceClassifier.classify(galaxy) == .mtpCandidate)
    }

    @Test func androidModesWithoutMTP() {
        #expect(USBDeviceClassifier.classify(.fixture(interfaces: [.androidADB])) == .androidWithoutMTP)
        #expect(USBDeviceClassifier.classify(.fixture(interfaces: [], settled: true)) == .androidWithoutMTP)
        #expect(USBDeviceClassifier.classify(.fixture(interfaces: [], settled: false)) == .pending)
        #expect(USBDeviceClassifier.classify(.fixture(interfaces: [.androidPTP])) == .androidPTPMode)
        // ADB on an unknown vendor still marks the device as Android.
        #expect(USBDeviceClassifier.classify(.fixture(vendorID: 0x1234, interfaces: [.androidADB])) == .androidWithoutMTP)
    }

    @Test func unsupportedAndIgnoredDevices() {
        #expect(USBDeviceClassifier.classify(.fixture(vendorID: 0x05AC, interfaces: [.stillImageUnnamed])) == .unsupported(.appleDevice))
        #expect(USBDeviceClassifier.classify(.fixture(vendorID: 0x04A9, interfaces: [.stillImageUnnamed])) == .unsupported(.ptpCamera))
        #expect(USBDeviceClassifier.classify(.fixture(vendorID: 0x1EA7, interfaces: [.hid])) == .ignored)
        #expect(USBDeviceClassifier.classify(.fixture(vendorID: 0x04E8, interfaces: [.massStorage])) == .ignored)
        #expect(USBDeviceClassifier.classify(.fixture(vendorID: 0x17EF, interfaces: [.hid])) == .ignored)
        #expect(USBDeviceClassifier.classify(.fixture(vendorID: 0x05AC, interfaces: [.hid])) == .ignored)
        #expect(USBDeviceClassifier.classify(.fixture(vendorID: 0x0BDA, interfaces: [.hub])) == .ignored)
        #expect(USBDeviceClassifier.classify(.fixture(vendorID: 0x1234, interfaces: [], settled: true)) == .ignored)
    }

    @Test func logicalIDSurvivesReEnumeration() {
        let charging = USBDeviceSnapshot.fixture(registryID: 1, productID: 0x4EE7, address: 3, interfaces: [.androidADB])
        let fileTransfer = USBDeviceSnapshot.fixture(registryID: 2, productID: 0x4EE1, address: 4, interfaces: [.androidMTP])
        #expect(charging.logicalID == fileTransfer.logicalID)
        let noSerial = USBDeviceSnapshot.fixture(serial: nil)
        #expect(noSerial.logicalID.rawValue.hasPrefix("loc:"))
    }

    @Test func libusbBusNumberComesFromLocationID() {
        var snapshot = USBDeviceSnapshot.fixture()
        snapshot.locationID = 0x0211_0000
        #expect(snapshot.busNumber == 2)
        #expect(MTPTarget(snapshot: snapshot) == MTPTarget(bus: 2, address: 5, vendorID: 0x18D1, productID: 0x4EE1))
    }

    @Test func exclusiveOwnerDescriptions() {
        #expect(IOKitUSBMonitor.describeOwner("pid 512, ptpcamerad", ownPID: 1) == "ptpcamerad (pid 512)")
        #expect(IOKitUSBMonitor.describeOwner("pid 77, PhoneBridge", ownPID: 77) == nil)
        #expect(IOKitUSBMonitor.describeOwner("Android File Transfer Agent", ownPID: 1) == "Android File Transfer Agent")
        #expect(IOKitUSBMonitor.describeOwner("", ownPID: 1) == nil)
    }
}

@Suite("MTPErrorMapper")
struct MTPErrorMapperTests {
    @Test func mapsBridgeStatusesToDeviceErrors() {
        #expect(MTPErrorMapper.map(status: .ok, nativeCode: 0, message: nil) == nil)
        #expect(MTPErrorMapper.map(status: .busy, nativeCode: -3, message: "claimed") == .deviceBusy(owner: nil))
        #expect(MTPErrorMapper.map(status: .noDevice, nativeCode: -4, message: nil) == .disconnected)
        #expect(MTPErrorMapper.map(status: .accessDenied, nativeCode: -3, message: nil) == .accessDenied)
        #expect(MTPErrorMapper.map(status: .openFailed, nativeCode: 7, message: "x") == .sessionOpenFailed(detail: "x"))
        #expect(MTPErrorMapper.map(status: .usbLayer, nativeCode: -1, message: "io") == .usbError(code: -1, detail: "io"))
        #expect(MTPErrorMapper.map(status: .ptpLayer, nativeCode: 2, message: "PTP 0x2009") == .protocolError(code: 2, detail: "PTP 0x2009"))
        #expect(MTPErrorMapper.map(status: .ptpLayer, nativeCode: 2, message: "PTP Layer error 02ff") == .disconnected)
        #expect(MTPErrorMapper.map(status: .timeout, nativeCode: -7, message: nil) == .timeout)
        #expect(MTPErrorMapper.map(status: .storageFull, nativeCode: 6, message: nil) == .storageFull)
        #expect(MTPErrorMapper.map(status: .cancelled, nativeCode: 8, message: nil) == .cancelled)
        #expect(MTPErrorMapper.map(status: .noInterface, nativeCode: 0, message: nil) == .noMTPInterface)
        #expect(MTPErrorMapper.map(status: .general, nativeCode: 1, message: "") == .unknown(detail: nil))
    }

    @Test func rawStatusesMatchTheCHeader() {
        // Guards against PBMTPBridge.h and BridgeStatus drifting apart.
        #expect(BridgeStatus(rawValue: Int32(PB_STATUS_OK.rawValue)) == .ok)
        #expect(BridgeStatus(rawValue: Int32(PB_STATUS_BUSY.rawValue)) == .busy)
        #expect(BridgeStatus(rawValue: Int32(PB_STATUS_NO_INTERFACE.rawValue)) == .noInterface)
        #expect(BridgeStatus(rawValue: Int32(PB_STATUS_GENERAL.rawValue)) == .general)
        #expect(MTPErrorMapper.map(rawStatus: 999, nativeCode: 0, message: "?") == .unknown(detail: "?"))
    }
}

@Suite("ConnectionState")
struct ConnectionStateTests {
    @Test func usbPresenceAndMTPAccessAreDistinct() {
        let usbOnly: [ConnectionState] = [.usbDetected, .waitingForMTP(.fileTransferModeRequired), .waitingForMTP(.deviceLocked),
                                          .connecting, .failed(.deviceBusy(owner: nil)), .unsupported(.appleDevice)]
        for state in usbOnly {
            #expect(state.isUSBPresent, "\(state.name)")
            #expect(!state.isMTPReady, "\(state.name)")
        }
        #expect(ConnectionState.connected.isUSBPresent && ConnectionState.connected.isMTPReady)
        #expect(!ConnectionState.reconnecting.isUSBPresent && !ConnectionState.disconnected.isUSBPresent)
    }

    @Test func storageInfoMapsPTPCodes() {
        let sd = StorageInfo(mtpStorageID: 0x0002_0001, description: "  ", volumeIdentifier: nil, storageType: 0x0004,
                             accessCapability: 0x0001, capacity: .max, freeSpace: .max)
        #expect(sd.kind == .removable)
        #expect(sd.isReadOnly)
        #expect(sd.capacity == nil && sd.freeSpace == nil)
        #expect(sd.name == "Storage 00020001")
    }
}

/// What reaches the public log (audit 2026-10-23, M12·M13; the rest is
/// checked by scripts/check-log-privacy.py).
@Suite("Public log values")
struct PublicLogValueTests {
    @Test func logDetailLeavesOutMacPathsAndSystemMessages() {
        let path = "/Users/hong/Downloads/가족사진.jpg"
        for error in [DeviceError.localWriteFailed(path: path, detail: "The file “가족사진.jpg” couldn’t be saved."),
                      .localReadFailed(path: path, detail: nil), .localPermissionDenied(path: path)] {
            #expect(error.technicalDetail?.contains("hong") == true, "still shown to the user under details")
            #expect(error.logDetail == nil)
        }
        #expect(DeviceError.usbError(code: -4, detail: "pipe").logDetail == "pipe · code -4")
        #expect(DeviceError.verificationFailed(expected: 10, actual: 3).logDetail == "expected 10 bytes, got 3")
    }

    @Test func errorSummaryHasNoNames() {
        let error = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/Users/hong/비밀 메모.txt"])
        #expect(error.localizedDescription.contains("비밀 메모"), "Cocoa quotes the file name")
        #expect(error.publicSummary == "NSCocoaErrorDomain 4")
    }
}
