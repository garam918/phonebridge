import Foundation

/// Why a USB-connected device is not (yet) usable over MTP.
enum WaitingReason: Equatable, Sendable {
    /// Android is in "charging only" (or tethering/MIDI) mode: no MTP interface.
    case fileTransferModeRequired
    /// Android is in "PTP / transfer photos" mode instead of "File transfer".
    case ptpModeSelected
    /// The MTP session is open but the device reports no storage: screen
    /// locked, "Allow access to device data?" not answered, or a USB mode other
    /// than "File transfer" (Samsung keeps its MTP interface in every mode and
    /// answers with no storage). The three cannot be told apart over USB.
    case deviceLocked
}

/// Connection lifecycle for one logical device.
///
/// USB presence and MTP access are deliberately separate: every state except
/// `disconnected` / `reconnecting` means "USB enumerated", only `connected`
/// means "MTP session open and storage readable".
enum ConnectionState: Equatable, Sendable {
    case disconnected
    case usbDetected
    case waitingForMTP(WaitingReason)
    case connecting
    case connected
    case reconnecting
    case failed(DeviceError)
    case unsupported(UnsupportedReason)
    /// "안전하게 연결 해제": the user closed the MTP session; the cable can be
    /// pulled. USB is still present; `retry` (다시 연결) reconnects.
    case safelyDisconnected

    var isUSBPresent: Bool {
        switch self {
        case .disconnected, .reconnecting: false
        default: true
        }
    }

    var isMTPReady: Bool { self == .connected }

    var isBusy: Bool {
        switch self {
        case .usbDetected, .connecting, .reconnecting: true
        case .waitingForMTP(.deviceLocked): true
        default: false
        }
    }

    var canRetry: Bool {
        switch self {
        case .failed, .waitingForMTP, .safelyDisconnected: true
        default: false
        }
    }

    /// Short identifier, used for logging and as part of localization keys.
    var name: String {
        switch self {
        case .disconnected: "disconnected"
        case .usbDetected: "usbDetected"
        case .waitingForMTP: "waitingForMTP"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        case .failed: "failed"
        case .unsupported: "unsupported"
        case .safelyDisconnected: "safelyDisconnected"
        }
    }
}
