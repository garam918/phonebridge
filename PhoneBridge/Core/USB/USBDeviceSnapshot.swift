import Foundation

struct USBInterfaceInfo: Hashable, Sendable {
    var number: UInt8
    var interfaceClass: UInt8
    var interfaceSubClass: UInt8
    var interfaceProtocol: UInt8
    /// iInterface string, e.g. "MTP", "PTP", "ADB Interface".
    var name: String?

    static let classImage: UInt8 = 0x06
    static let classVendorSpecific: UInt8 = 0xFF
    static let classHID: UInt8 = 0x03
    static let classMassStorage: UInt8 = 0x08
    static let classHub: UInt8 = 0x09

    var isStillImage: Bool { interfaceClass == Self.classImage && interfaceSubClass == 0x01 && interfaceProtocol == 0x01 }
    var isADB: Bool { interfaceClass == Self.classVendorSpecific && interfaceSubClass == 0x42 && interfaceProtocol == 0x01 }

    func nameContains(_ token: String) -> Bool {
        name?.range(of: token, options: .caseInsensitive) != nil
    }
}

/// Immutable view of one IOUSBHostDevice, as read from the IORegistry.
struct USBDeviceSnapshot: Hashable, Sendable {
    var registryID: UInt64
    var vendorID: UInt16
    var productID: UInt16
    var vendorName: String?
    var productName: String?
    var serialNumber: String?
    var locationID: UInt32
    var address: UInt8
    var interfaces: [USBInterfaceInfo]
    /// False while the device was just published and its interfaces may still
    /// be appearing. The monitor re-sends the snapshot once they settled.
    var interfacesSettled: Bool

    /// libusb's darwin backend uses `locationID >> 24` as the bus number.
    var busNumber: UInt32 { locationID >> 24 }

    var logicalID: DeviceID {
        if let serial = serialNumber?.trimmingCharacters(in: .whitespaces), !serial.isEmpty {
            return DeviceID(String(format: "usb:%04x:", vendorID) + serial)
        }
        return DeviceID(String(format: "loc:%08x", locationID))
    }

    var displayName: String {
        let product = productName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !product.isEmpty { return product }
        let vendor = vendorName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !vendor.isEmpty { return vendor }
        return String(format: "USB %04X:%04X", vendorID, productID)
    }

    var idPairDescription: String { String(format: "%04X:%04X", vendorID, productID) }
}
