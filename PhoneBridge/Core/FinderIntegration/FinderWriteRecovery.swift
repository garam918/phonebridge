import Foundation
import Observation

/// A file written in Finder whose bytes never reached the device: the upload
/// failed, the volume was unmounted, or the extension stopped (W3).
struct RecoverableFile: Identifiable, Hashable, Sendable {
    /// Buffer file name in the write buffer folder.
    let id: String
    /// nil when the manifest is missing (name unknown).
    let fileName: String?
    let volumeName: String?
    let folderPath: [String]
    let size: UInt64
    let updated: Date
    let uploadFailed: Bool
    let lastError: String?
    /// Still held by a mounted volume: it can be saved, not discarded.
    let inUse: Bool
}

/// Finds unsaved Finder writes in the App Group buffer folder and lets the
/// user keep them on the Mac or discard them. Nothing is removed silently
/// except macOS bookkeeping files and empty buffers nobody uses.
@MainActor
@Observable
final class FinderWriteRecovery {
    private(set) var files: [RecoverableFile] = []
    @ObservationIgnored let directory: URL?

    init(directory: URL?) {
        self.directory = directory
    }

    /// Rebuilds `files`; returns how many were not listed before.
    @discardableResult
    func scan() -> Int {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            files = []
            return 0
        }
        let known = Set(files.map(\.id))
        let manifestSuffix = "." + WriteBufferManifest.fileExtension
        var found: [RecoverableFile] = []
        let buffers = Set(names.filter { !$0.hasSuffix(manifestSuffix) })
        for name in names where name.hasSuffix(manifestSuffix) {
            let buffer = String(name.dropLast(manifestSuffix.count))
            if !buffers.contains(buffer) { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
        }
        // Only names the extension makes (`FinderWritePolicy.newBufferName`).
        for buffer in buffers.sorted() where FinderIPC.isValidBufferName(buffer)
            && (buffer.hasPrefix("w-") || buffer.hasPrefix(FinderWritePolicy.shadowBufferPrefix)) {
            let url = directory.appending(path: buffer)
            let inUse = WriteBufferLock.isHeld(url)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = attributes?[.modificationDate] as? Date ?? Date()
            let manifest = (try? Data(contentsOf: directory.appending(path: WriteBufferManifest.manifestName(for: buffer))))
                .flatMap { try? JSONDecoder().decode(WriteBufferManifest.self, from: $0) }
            if let manifest {
                guard !inUse || manifest.state == .failed else { continue }
                found.append(RecoverableFile(id: buffer, fileName: manifest.fileName, volumeName: manifest.volumeName,
                                             folderPath: manifest.folderPath, size: size, updated: manifest.updated,
                                             uploadFailed: manifest.state == .failed, lastError: manifest.lastError, inUse: inUse))
            } else if !inUse {
                // Shadow files (`._*`, `.DS_Store`) and empty buffers are not user data.
                if buffer.hasPrefix(FinderWritePolicy.shadowBufferPrefix) || size == 0 || Self.isBookkeeping(url) {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    found.append(RecoverableFile(id: buffer, fileName: nil, volumeName: nil, folderPath: [], size: size,
                                                 updated: modified, uploadFailed: false, lastError: nil, inUse: false))
                }
            }
        }
        files = found.sorted { $0.updated > $1.updated }
        return files.filter { !known.contains($0.id) }.count
    }

    /// Copies the file to `destination` (replacing what is there, as the save
    /// panel already asked) and forgets it unless a volume still uses it. The
    /// copy is made first and swapped in atomically, so a failed copy (full
    /// disk, buffer gone) leaves the existing file alone (audit 2026-10-23, M4).
    func save(_ file: RecoverableFile, to destination: URL) throws {
        guard let directory else { return }
        let source = directory.appending(path: file.id)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else {
            try fileManager.copyItem(at: source, to: destination)
            if !file.inUse { remove(file) }
            scan()
            return
        }
        let scratch = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let copy = scratch.appending(path: destination.lastPathComponent)
        try fileManager.copyItem(at: source, to: copy)
        _ = try fileManager.replaceItemAt(destination, withItemAt: copy)
        if !file.inUse { remove(file) }
        scan()
    }

    func discard(_ file: RecoverableFile) {
        guard !file.inUse else { return }
        remove(file)
        scan()
    }

    /// `.DS_Store` ("\0\0\0\u{1}Bud1") or AppleDouble ("\0\u{5}\u{16}\u{7}") contents,
    /// e.g. buffers from builds that did not mark shadow files yet.
    static func isBookkeeping(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        return head == Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31]) || head.prefix(4) == Data([0, 5, 0x16, 7])
    }

    private func remove(_ file: RecoverableFile) {
        guard let directory, !WriteBufferLock.isHeld(directory.appending(path: file.id)) else { return }
        for name in [file.id, WriteBufferManifest.manifestName(for: file.id)] {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}
