import Foundation

/// Sidecar `<buffer>.json` the extension keeps next to every write buffer of
/// a real file (not for `._*`/`.DS_Store`), so the app can offer the bytes
/// back when they never reached the device (W3).
struct WriteBufferManifest: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Being written, or waiting for its upload.
        case writing
        /// The upload failed; the file is still in the extension.
        case failed
    }

    var bufferName: String
    var volume: VolumeAddress
    var volumeName: String
    /// Folder names from the storage root (best effort).
    var folderPath: [String]
    var fileName: String
    var state: State
    var updated: Date
    var lastError: String?

    static let fileExtension = "json"

    static func manifestName(for bufferName: String) -> String {
        "\(bufferName).\(fileExtension)"
    }
}

/// Advisory lock the extension holds on each buffer it still uses. A buffer
/// nobody holds belongs to an unmounted volume or a crashed extension.
enum WriteBufferLock {
    /// Opens and locks `url`; returns the descriptor to keep, or -1.
    static func acquire(_ url: URL) -> Int32 {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    static func release(_ fd: Int32) {
        if fd >= 0 { close(fd) }
    }

    /// true while another open file (normally the extension) holds the lock.
    static func isHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
