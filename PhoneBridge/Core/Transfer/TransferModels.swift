import Foundation
import Observation

/// A device object plus its path of names from the storage root. The path
/// lets a retried job find the object again after a reconnect, when MTP
/// handles from the old session are no longer valid.
struct DeviceItemRef: Hashable, Sendable, Codable {
    var id: FileItemID
    var name: String
    var isFolder: Bool
    var size: UInt64?
    var modified: Date?
    /// Names from the storage root to the item, inclusive.
    var path: [String]

    init(item: FileItem, parentPath: [String]) {
        id = item.id
        name = item.name
        isFolder = item.isFolder
        size = item.size
        modified = item.modified
        path = parentPath + [item.name]
    }

    var fileItem: FileItem {
        FileItem(id: id, name: name, isFolder: isFolder, size: size, modified: modified)
    }
}

/// A device folder (storage root when `path` is empty).
struct DeviceFolderRef: Hashable, Sendable, Codable {
    var id: FileItemID
    var path: [String]
}

enum TransferKind: String, Sendable, Equatable {
    case download, upload, copy, move, delete
}

enum TransferRequest: Sendable, Equatable {
    case download(items: [DeviceItemRef], generation: UInt64, destination: URL, deleteSourceAfter: Bool)
    case upload(sources: [URL], destination: DeviceFolderRef, generation: UInt64, removeSourceAfter: Bool)
    case deviceCopy(items: [DeviceItemRef], destination: DeviceFolderRef, generation: UInt64, move: Bool)
    case delete(items: [DeviceItemRef], generation: UInt64)

    var deviceID: DeviceID {
        switch self {
        case .download(let items, _, _, _), .deviceCopy(let items, _, _, _), .delete(let items, _):
            items.first?.id.deviceID ?? DeviceID("")
        case .upload(_, let destination, _, _):
            destination.id.deviceID
        }
    }

    var kind: TransferKind {
        switch self {
        case .download(_, _, _, let deleteSource): deleteSource ? .move : .download
        case .upload(_, _, _, let removeSource): removeSource ? .move : .upload
        case .deviceCopy(_, _, _, let move): move ? .move : .copy
        case .delete: .delete
        }
    }

    var itemNames: [String] {
        switch self {
        case .download(let items, _, _, _), .deviceCopy(let items, _, _, _), .delete(let items, _): items.map(\.name)
        case .upload(let sources, _, _, _): sources.map(\.lastPathComponent)
        }
    }
}

enum TransferJobState: Equatable, Sendable {
    case queued
    case running
    case completed
    case failed(DeviceError)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

/// One user action in the transfer queue (a file, a folder, or a selection).
@MainActor
@Observable
final class TransferJob: Identifiable {
    let id = UUID()
    let request: TransferRequest
    let destinationName: String
    /// Downloaded for a drag to Finder or another app (file promise); the
    /// receiving app has given up by the time it fails, so it is not retried.
    let isDragExport: Bool
    let createdAt = Date()

    var state: TransferJobState = .queued
    /// Bytes of all files in the job (known after planning).
    var totalBytes: UInt64 = 0
    /// Bytes of files already finished.
    var finishedBytes: UInt64 = 0
    /// Progress inside the current file.
    var currentBytes: UInt64 = 0
    var currentTotal: UInt64 = 0
    var totalFiles = 0
    var finishedFiles = 0
    var skippedFiles = 0
    var currentName: String?
    var bytesPerSecond: Double = 0
    /// Staging leftovers that could not be removed (shown to the user).
    var warnings: [String] = []
    /// Source folders of a move that were left on the device because they
    /// still held items the move did not copy (shown to the user).
    var keptFolders: [String] = []

    @ObservationIgnored var progress: TransferProgress?
    @ObservationIgnored var cancelRequested = false

    init(request: TransferRequest, destinationName: String, isDragExport: Bool = false) {
        self.request = request
        self.destinationName = destinationName
        self.isDragExport = isDragExport
    }

    var kind: TransferKind { request.kind }
    var deviceID: DeviceID { request.deviceID }
    var title: String { request.itemNames.first ?? "" }
    var itemCount: Int { request.itemNames.count }
    var transferredBytes: UInt64 { finishedBytes + currentBytes }

    /// 0...1, or nil while the size is still unknown.
    var fractionCompleted: Double? {
        switch kind {
        case .delete:
            return totalFiles > 0 ? Double(finishedFiles + skippedFiles) / Double(totalFiles) : nil
        default:
            if totalBytes > 0 { return min(1, Double(transferredBytes) / Double(totalBytes)) }
            if totalFiles > 0 { return Double(finishedFiles + skippedFiles) / Double(totalFiles) }
            return state == .completed ? 1 : nil
        }
    }

    var currentFileFraction: Double? {
        currentTotal > 0 ? min(1, Double(currentBytes) / Double(currentTotal)) : nil
    }

    var canRetry: Bool {
        guard !isDragExport else { return false }
        return switch state {
        case .failed(let error): error.isRetryable
        case .cancelled: true
        default: false
        }
    }
}

enum ConflictAction: Sendable, Equatable {
    /// Replace the existing file (folders: merge into it).
    case replace
    case keepBoth
    case skip
}

struct ConflictDecision: Sendable, Equatable {
    var action: ConflictAction
    var applyToAll: Bool

    static func always(_ action: ConflictAction) -> ConflictDecision {
        ConflictDecision(action: action, applyToAll: true)
    }
}

/// A name collision the user has to decide about.
struct TransferConflict: Identifiable, Sendable, Equatable {
    let id = UUID()
    let kind: TransferKind
    let name: String
    let isFolder: Bool
    let destinationName: String
    let existingSize: UInt64?
    let existingModified: Date?
    let incomingSize: UInt64?
    let incomingModified: Date?
    /// False when the target cannot replace safely (e.g. no MTP rename).
    let canReplace: Bool
}
