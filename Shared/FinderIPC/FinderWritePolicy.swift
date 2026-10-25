import Foundation

/// Decisions of the extension's write path that do not need FSKit
/// (FINDER_WRITE_W0.md conclusions), kept here so the app's tests cover them.
enum FinderWritePolicy {
    /// macOS bookkeeping files: kept in the extension only, never on the device.
    static func isShadowName(_ name: String) -> Bool {
        name.hasPrefix("._") || shadowNames.contains(name)
    }

    static let shadowNames: Set<String> = [
        ".DS_Store", ".localized", ".VolumeIcon.icns", ".com.apple.timemachine.donotpresent",
    ]

    /// Folders macOS would create for its own use (trash, indexes, events);
    /// refusing them keeps Finder from treating the device as a Mac disk.
    static func isRefusedFolderName(_ name: String) -> Bool {
        [".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100"].contains(name)
    }

    /// New files closed while still empty wait this long before they are
    /// created on the device: Finder makes an empty placeholder for every copy
    /// and deletes it right away (W0).
    static let emptyFileDelay: TimeInterval = 2

    enum CloseAction: Equatable {
        /// Nothing to send (still open for writing, unchanged, or a shadow file).
        case none
        /// Upload now; the close reply carries the result.
        case commit
        /// An empty new file: create it after `emptyFileDelay` unless it is
        /// written, renamed over or removed first.
        case commitLater
    }

    /// What the last close of a writer means for a file.
    /// - Parameters:
    ///   - writersLeft: handles still open for writing after this close.
    ///   - isShadow: bookkeeping file (`isShadowName`).
    ///   - isOnDevice: the device already has this file (edits replace it).
    ///   - isDirty: the local buffer changed since the last commit.
    ///   - size: current size of the local buffer.
    static func closeAction(writersLeft: Int, isShadow: Bool, isOnDevice: Bool, isDirty: Bool, size: UInt64) -> CloseAction {
        guard writersLeft == 0, !isShadow else { return .none }
        if isOnDevice { return isDirty ? .commit : .none }
        // A new file is uploaded even when it was never written to.
        return size == 0 ? .commitLater : .commit
    }

    /// Unique, valid buffer file name (see `FinderIPC.isValidBufferName`):
    /// `w-…` for real files, `s-…` for shadow files (never offered for recovery).
    static func newBufferName(shadow: Bool = false) -> String {
        (shadow ? shadowBufferPrefix : "w-") + UUID().uuidString.lowercased()
    }

    static let shadowBufferPrefix = "s-"
}
