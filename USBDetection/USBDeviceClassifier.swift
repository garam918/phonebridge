import Foundation

/// What a USB device means for PhoneBridge, decided only from USB descriptors.
/// "MTP candidate" does not mean MTP works: that is only known after the
/// broker opened a session.
enum USBDeviceClass: Equatable, Sendable {
    case mtpCandidate
    case androidWithoutMTP
    case androidPTPMode
    /// Known Android vendor whose interfaces are not enumerated yet.
    case pending
    case unsupported(UnsupportedReason)
    /// Not relevant (mouse, hub, monitor controls, SSD, ...); never shown.
    case ignored
}

enum UnsupportedReason: Equatable, Sendable {
    /// iPhone / iPad exposes a PTP camera interface but is not an Android device.
    case appleDevice
    /// A plain PTP camera that does not speak MTP.
    case ptpCamera
}

enum USBDeviceClassifier {
    /// USB vendor ids of Android phone/tablet makers. Some of these vendors also
    /// make keyboards, monitors or SSDs, so a vendor match alone is not enough.
    static let androidVendorIDs: Set<UInt16> = [
        0x18D1, // Google
        0x04E8, // Samsung
        0x1004, // LG
        0x22B8, // Motorola
        0x0FCE, // Sony
        0x0BB4, // HTC
        0x12D1, // Huawei
        0x2717, // Xiaomi
        0x2A70, // OnePlus
        0x22D9, // OPPO / realme
        0x2D95, // vivo
        0x0B05, // ASUS
        0x17EF, // Lenovo
        0x19D2, // ZTE
        0x2E04, // HMD (Nokia)
        0x04DD, // Sharp
        0x0482, // Kyocera
        0x10A9, // Pantech
    ]

    static let appleVendorID: UInt16 = 0x05AC

    /// Interface classes a phone exposes in non-storage modes (vendor-specific
    /// MTP/ADB, CDC/RNDIS tethering, MIDI/audio).
    private static let phoneLikeClasses: Set<UInt8> = [0xFF, 0x02, 0x0A, 0xE0, 0xEF, 0x01, 0x06]

    static func classify(_ device: USBDeviceSnapshot) -> USBDeviceClass {
        let interfaces = device.interfaces

        if interfaces.contains(where: { $0.interfaceClass == USBInterfaceInfo.classHub }) {
            return .ignored
        }

        let hasADB = interfaces.contains(where: \.isADB)
        let isAndroidVendor = androidVendorIDs.contains(device.vendorID)
        let isAndroid = isAndroidVendor || hasADB

        // Android's MTP function (and Samsung's) names its interface "MTP".
        if interfaces.contains(where: { $0.nameContains("MTP") &&
            ($0.interfaceClass == USBInterfaceInfo.classVendorSpecific || $0.interfaceClass == USBInterfaceInfo.classImage) }) {
            return .mtpCandidate
        }

        if let stillImage = interfaces.first(where: \.isStillImage) {
            if device.vendorID == appleVendorID {
                return .unsupported(.appleDevice)
            }
            if isAndroid {
                // Android "PTP" mode names the interface "PTP"; older devices
                // used class 6 for real MTP without a name, so let libmtp try.
                return stillImage.nameContains("PTP") ? .androidPTPMode : .mtpCandidate
            }
            return .unsupported(.ptpCamera)
        }

        guard isAndroid else { return .ignored }

        if interfaces.isEmpty {
            return device.interfacesSettled ? .androidWithoutMTP : .pending
        }
        // Same vendors also make HID devices, SSDs and monitors.
        if interfaces.allSatisfy({ phoneLikeClasses.contains($0.interfaceClass) }) || hasADB {
            return .androidWithoutMTP
        }
        return .ignored
    }
}
