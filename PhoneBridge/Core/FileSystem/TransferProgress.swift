import Foundation
import Synchronization

/// Lock-protected channel between a blocking transfer (running on a device
/// session queue or a background thread) and the main-actor observer.
/// Cancellation is a flag the transfer loop polls between chunks; it never
/// needs to hop onto the busy session actor.
final class TransferProgress: Sendable {
    private struct State {
        var completed: UInt64 = 0
        var total: UInt64 = 0
        var cancelled = false
    }

    private let state = Mutex(State())

    init() {}

    func update(completed: UInt64, total: UInt64) {
        state.withLock {
            $0.completed = completed
            $0.total = total
        }
    }

    var completed: UInt64 { state.withLock { $0.completed } }
    var total: UInt64 { state.withLock { $0.total } }

    func cancel() {
        state.withLock { $0.cancelled = true }
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }
}

/// What a device lets PhoneBridge do beyond browsing and downloading.
struct FileSystemCapabilities: Equatable, Sendable {
    /// Upload, create folders, delete.
    var canWrite: Bool
    var canRename: Bool
    /// Native MTP MoveObject (otherwise moves fall back to copy + delete).
    var canMoveNatively: Bool
    /// Native MTP CopyObject (otherwise copies go through a temporary download).
    var canCopyNatively: Bool
    var canThumbnail: Bool
    /// Arbitrary-offset reads without downloading the whole object.
    var canReadPartially: Bool = false
    /// Large uploads go in pieces (Android edit extension), so browsing the
    /// same device does not wait for the whole upload.
    var canUploadInChunks: Bool = false
    /// Items can be deleted although nothing can be written (iPhone/iPad
    /// photos: browse, copy to the Mac, delete — D75).
    var allowsDeleteWithoutWrite: Bool = false

    var canDelete: Bool { canWrite || allowsDeleteWithoutWrite }

    static let full = FileSystemCapabilities(canWrite: true, canRename: true, canMoveNatively: true,
                                             canCopyNatively: true, canThumbnail: true, canReadPartially: true)
    static let readOnly = FileSystemCapabilities(canWrite: false, canRename: false, canMoveNatively: false,
                                                 canCopyNatively: false, canThumbnail: true)
}

/// Opens local files for the fd-based MTP transfer calls and maps errno to
/// `DeviceError`.
enum LocalFileIO {
    static func openForReading(_ url: URL) throws(DeviceError) -> Int32 {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw mapErrno(errno, url: url, writing: false) }
        return fd
    }

    /// Creates (or truncates) `url` for writing.
    static func openForWriting(_ url: URL) throws(DeviceError) -> Int32 {
        let fd = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw mapErrno(errno, url: url, writing: true) }
        return fd
    }

    static func mapErrno(_ code: Int32, url: URL, writing: Bool) -> DeviceError {
        let path = url.path(percentEncoded: false)
        switch code {
        case EACCES, EPERM, EROFS: return .localPermissionDenied(path: path)
        case ENOSPC, EDQUOT: return .insufficientLocalSpace(required: 0, available: 0)
        default:
            let detail = String(cString: strerror(code))
            return writing ? .localWriteFailed(path: path, detail: detail) : .localReadFailed(path: path, detail: detail)
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data, url: URL) throws(DeviceError) {
        let result: Int32 = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return 0
        }
        if result != 0 { throw mapErrno(result, url: url, writing: true) }
    }

    /// `directory/<name>` for a name that came from a device. The name is made
    /// a single component (`FileNameRules.singleComponent`), and anything that
    /// would still not land directly inside `directory` is refused.
    static func child(of directory: URL, named name: String, isDirectory: Bool = false) throws(DeviceError) -> URL {
        let component = FileNameRules.singleComponent(name)
        let url = directory.appending(path: component, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        let parent = directory.standardizedFileURL.pathComponents
        let resolved = url.standardizedFileURL.pathComponents
        guard resolved.count == parent.count + 1, Array(resolved.dropLast()) == parent, resolved.last == component else {
            throw .invalidName
        }
        return url
    }

    /// `child(of:named:)` for each of `names` in turn (a path below `directory`).
    static func descendant(of directory: URL, path names: [String]) throws(DeviceError) -> URL {
        var url = directory
        for name in names { url = try child(of: url, named: name) }
        return url
    }

    static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber)?.uint64Value
    }
}
