import Foundation

extension USBDeviceSnapshot {
    var logicalID: DeviceID { DeviceID(logicalKey) }
}
