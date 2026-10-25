import Foundation

/// Status codes of PBMTPBridge.h, mirrored so the mapping is testable without
/// touching the C library.
enum BridgeStatus: Int32, Sendable {
    case ok = 0
    case noDevice = 1
    case busy = 2
    case accessDenied = 3
    case openFailed = 4
    case ptpLayer = 5
    case usbLayer = 6
    case memory = 7
    case storageFull = 8
    case cancelled = 9
    case timeout = 10
    case invalidArgument = 11
    case notFound = 12
    case noInterface = 13
    case general = 14
}

enum MTPErrorMapper {
    static func map(status: BridgeStatus, nativeCode: Int32, message: String?) -> DeviceError? {
        let detail = message.flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case .ok: return nil
        case .noDevice: return .disconnected
        case .busy: return .deviceBusy(owner: nil)
        case .accessDenied: return .accessDenied
        case .openFailed: return .sessionOpenFailed(detail: detail)
        case .ptpLayer:
            // libmtp reports a pulled cable as PTP_ERROR_IO (0x02FF).
            if let detail, detail.localizedCaseInsensitiveContains("02ff") { return .disconnected }
            return .protocolError(code: nativeCode, detail: detail)
        case .usbLayer: return .usbError(code: nativeCode, detail: detail)
        case .memory: return .outOfMemory
        case .storageFull: return .storageFull
        case .cancelled: return .cancelled
        case .timeout: return .timeout
        case .notFound: return .objectNotFound
        case .noInterface: return .noMTPInterface
        case .invalidArgument, .general: return .unknown(detail: detail)
        }
    }

    static func map(rawStatus: Int32, nativeCode: Int32, message: String?) -> DeviceError? {
        map(status: BridgeStatus(rawValue: rawStatus) ?? .general, nativeCode: nativeCode, message: message)
    }
}
