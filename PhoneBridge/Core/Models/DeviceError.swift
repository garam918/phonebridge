import Foundation

/// Every failure that reaches the UI is one of these. Native libmtp/libusb
/// codes are translated by `MTPErrorMapper`; the UI localizes via
/// `localizationKey`.
enum DeviceError: Error, Equatable, Sendable {
    /// Another process holds the MTP interface (Image Capture's ptpcamerad,
    /// Android File Transfer, OpenMTP, Smart Switch, ...). `owner` is the
    /// process name when IOKit tells us.
    case deviceBusy(owner: String?)
    case accessDenied
    case sessionOpenFailed(detail: String?)
    case noMTPInterface
    case disconnected
    case objectNotFound
    case protocolError(code: Int32, detail: String?)
    case usbError(code: Int32, detail: String?)
    case timeout
    case cancelled
    case storageFull
    case outOfMemory
    case unknown(detail: String?)

    // File management / transfers
    case insufficientLocalSpace(required: UInt64, available: UInt64)
    case insufficientDeviceSpace(required: UInt64, available: UInt64)
    case localPermissionDenied(path: String)
    case localReadFailed(path: String, detail: String?)
    case localWriteFailed(path: String, detail: String?)
    /// The transferred copy does not match the source (size check).
    case verificationFailed(expected: UInt64, actual: UInt64)
    case readOnlyStorage
    case unsupportedOperation
    case invalidName
    case nameConflict(name: String)
    /// E.g. moving a folder into itself.
    case invalidDestination
    /// A folder still has visible items (Finder deletes contents first).
    case folderNotEmpty
    /// The device cannot move objects between folders (no MoveObject);
    /// Finder then copies and deletes instead.
    case crossFolderMoveUnsupported

    var localizationKey: String {
        switch self {
        case .deviceBusy: "error.deviceBusy"
        case .accessDenied: "error.accessDenied"
        case .sessionOpenFailed: "error.sessionOpenFailed"
        case .noMTPInterface: "error.noMTPInterface"
        case .disconnected: "error.disconnected"
        case .objectNotFound: "error.objectNotFound"
        case .protocolError: "error.protocol"
        case .usbError: "error.usb"
        case .timeout: "error.timeout"
        case .cancelled: "error.cancelled"
        case .storageFull: "error.storageFull"
        case .outOfMemory: "error.outOfMemory"
        case .unknown: "error.unknown"
        case .insufficientLocalSpace: "error.insufficientLocalSpace"
        case .insufficientDeviceSpace: "error.insufficientDeviceSpace"
        case .localPermissionDenied: "error.localPermissionDenied"
        case .localReadFailed: "error.localReadFailed"
        case .localWriteFailed: "error.localWriteFailed"
        case .verificationFailed: "error.verificationFailed"
        case .readOnlyStorage: "error.readOnlyStorage"
        case .unsupportedOperation: "error.unsupportedOperation"
        case .invalidName: "error.invalidName"
        case .nameConflict: "error.nameConflict"
        case .invalidDestination: "error.invalidDestination"
        case .folderNotEmpty: "error.folderNotEmpty"
        case .crossFolderMoveUnsupported: "error.crossFolderMoveUnsupported"
        }
    }

    /// Developer-facing detail (libmtp/libusb message); shown under "details".
    var technicalDetail: String? {
        switch self {
        case .deviceBusy(let owner): owner
        case .sessionOpenFailed(let detail), .unknown(let detail): detail
        case .protocolError(let code, let detail), .usbError(let code, let detail):
            [detail, "code \(code)"].compactMap { $0 }.joined(separator: " · ")
        case .localPermissionDenied(let path): path
        case .localReadFailed(let path, let detail), .localWriteFailed(let path, let detail):
            [path, detail].compactMap { $0 }.joined(separator: " · ")
        case .verificationFailed(let expected, let actual): "expected \(expected) bytes, got \(actual)"
        case .insufficientLocalSpace(let required, let available), .insufficientDeviceSpace(let required, let available):
            "required \(required) bytes, available \(available)"
        default: nil
        }
    }

    /// `technicalDetail` for the public log: without Mac paths and the system
    /// messages that quote file names (audit 2026-10-23, M13).
    var logDetail: String? {
        switch self {
        case .localPermissionDenied, .localReadFailed, .localWriteFailed: nil
        default: technicalDetail
        }
    }

    /// Whether running the same request again can reasonably succeed.
    var isRetryable: Bool {
        switch self {
        case .invalidName, .invalidDestination, .unsupportedOperation, .readOnlyStorage: false
        default: true
        }
    }
}
