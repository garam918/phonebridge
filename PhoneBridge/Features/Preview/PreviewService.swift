import AppKit
import Foundation
import Observation

/// Quick Look previews and inspector thumbnails for device files.
///
/// Previews need a local copy: the file is downloaded once into the app's
/// cache (staging file, size-verified) and reused while the session lasts.
/// Thumbnails come from MTP's embedded thumbnail, no full download.
@MainActor
@Observable
final class PreviewService {
    static let maximumPreviewSize: UInt64 = 1024 * 1024 * 1024

    /// Bound to `.quickLookPreview`.
    var previewURL: URL?
    private(set) var preparingName: String?
    private(set) var preparingFraction: Double?
    private(set) var lastError: DeviceError?

    /// Most recently shown thumbnails (MTP thumbnails are small, ~160 px).
    @ObservationIgnored private var thumbnails = LRUCache<FileItemID, NSImage>(capacity: PreviewService.thumbnailCacheSize)
    /// Items without a thumbnail, so they are not asked again.
    @ObservationIgnored private var failedThumbnails = LRUCache<FileItemID, Bool>(capacity: 4 * PreviewService.thumbnailCacheSize)
    nonisolated static let thumbnailCacheSize = 600
    @ObservationIgnored private var currentProgress: TransferProgress?
    @ObservationIgnored private let cacheDirectory: URL
    /// Downloaded previews kept in one session; the oldest go first beyond this.
    @ObservationIgnored let cacheLimit: UInt64

    init(cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "Previews", directoryHint: .isDirectory),
         cacheLimit: UInt64 = 2 << 30) {
        self.cacheDirectory = cacheDirectory
        self.cacheLimit = cacheLimit
    }

    func canPreview(_ item: FileItem) -> Bool {
        !item.isFolder && FileCategory.isPreviewable(fileName: item.name) && (item.size ?? 0) <= Self.maximumPreviewSize
    }

    /// Downloads (if needed) and opens Quick Look.
    func preview(_ item: FileItem, in fileSystem: any DeviceFileSystem) async {
        guard canPreview(item) else { return }
        cancel()
        lastError = nil
        let folder = cacheDirectory
            .appending(path: "\(abs(item.id.deviceID.rawValue.hashValue))-\(fileSystem.generation)-\(item.id.storageID)-\(item.id.objectID)-\(item.size ?? 0)",
                       directoryHint: .isDirectory)
        guard let target = try? LocalFileIO.child(of: folder, named: item.name) else { return }
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path(percentEncoded: false))
            previewURL = target
            return
        }

        let progress = TransferProgress()
        currentProgress = progress
        preparingName = item.name
        preparingFraction = 0
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { break }
                let total = progress.total
                self?.preparingFraction = total > 0 ? Double(progress.completed) / Double(total) : nil
            }
        }
        defer {
            ticker.cancel()
            if currentProgress === progress {
                currentProgress = nil
                preparingName = nil
                preparingFraction = nil
            }
        }

        let staging = folder.appending(path: FileNameRules.temporaryName(suffix: "preview"))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await fileSystem.download(item.id, to: staging, progress: progress)
            if let expected = item.size, LocalFileIO.fileSize(staging) != expected {
                throw DeviceError.verificationFailed(expected: expected, actual: LocalFileIO.fileSize(staging) ?? 0)
            }
            try FileManager.default.moveItem(at: staging, to: target)
            trimCache(keeping: folder)
            guard !progress.isCancelled else { return }
            previewURL = target
        } catch {
            try? FileManager.default.removeItem(at: staging)
            let mapped = (error as? DeviceError) ?? TransferManager.mapLocal(error, url: target, writing: true)
            if mapped != .cancelled {
                lastError = mapped
                Log.preview.error("preview of \(item.name, privacy: .private) failed: \(mapped.localizationKey, privacy: .public)")
            }
        }
    }

    func previewLocal(_ url: URL) {
        previewURL = url
    }

    func cancel() {
        currentProgress?.cancel()
    }

    func dismissError() {
        lastError = nil
    }

    func cachedThumbnail(for item: FileItem) -> NSImage? {
        thumbnails.value(for: item.id)
    }

    /// Embedded MTP thumbnail for images/videos; nil when the device has none.
    func thumbnail(for item: FileItem, in fileSystem: any DeviceFileSystem) async -> NSImage? {
        if let cached = thumbnails.value(for: item.id) { return cached }
        guard fileSystem.capabilities.canThumbnail, !failedThumbnails.contains(item.id),
              item.category == .image || item.category == .video else { return nil }
        guard let data = try? await fileSystem.thumbnail(item.id), let image = NSImage(data: data) else {
            failedThumbnails.insert(true, for: item.id)
            return nil
        }
        thumbnails.insert(image, for: item.id)
        return image
    }

    /// Total bytes of downloaded previews on disk.
    var cacheSize: UInt64 {
        cacheFolders().reduce(0) { $0 + $1.size }
    }

    /// Removes the least recently used previews until the cache fits `cacheLimit`.
    /// The preview just opened (`keeping`) always stays.
    func trimCache(keeping: URL? = nil) {
        var folders = cacheFolders().sorted { $0.used < $1.used }
        var total = folders.reduce(0) { $0 + $1.size }
        while total > cacheLimit, let oldest = folders.first {
            folders.removeFirst()
            if oldest.url.standardizedFileURL == keeping?.standardizedFileURL { continue }
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }

    private func cacheFolders() -> [(url: URL, size: UInt64, used: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys) else {
            return []
        }
        return folders.map { folder in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            let size = files.reduce(UInt64(0)) { total, file in
                total + UInt64((try? file.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0)
            }
            let used = (try? folder.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            return (folder, size, used)
        }
    }

    /// Previews are disposable; clear them at launch and quit.
    func purgeCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        thumbnails.removeAll()
        failedThumbnails.removeAll()
    }
}
