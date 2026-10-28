import Foundation

/// One photo, video or folder on an iPhone/iPad, as Image Capture lists it
/// (DCIM/100APPLE/IMG_0001.HEIC …).
struct CameraEntry: Equatable, Sendable {
    var id: UInt32
    /// `FileItemID.rootObjectID` for top-level entries.
    var parentID: UInt32
    var name: String
    var isFolder: Bool
    var size: UInt64?
    var modified: Date?
}

/// What PhoneBridge needs from an Image Capture camera device (D75). The real
/// implementation wraps `ICCameraDevice`; tests use a fake.
protocol CameraBackend: AnyObject, Sendable {
    /// The current content catalog (changes when photos are added or deleted).
    func catalog() async throws(DeviceError) -> [CameraEntry]
    func read(_ id: UInt32, offset: UInt64, length: Int) async throws(DeviceError) -> Data
    func thumbnail(_ id: UInt32) async throws(DeviceError) -> Data
    /// Deletes files (not folders); throws if the device refuses any of them.
    func delete(_ ids: [UInt32]) async throws(DeviceError)
}

/// An iPhone/iPad's photos and videos as a `DeviceFileSystem`, so browsing,
/// Quick Look, thumbnails, the transfer queue (staging, size check), drag to
/// Finder and delete work as they do for Android. iOS only allows reading and
/// deleting camera-roll files: nothing can be written, renamed or moved.
final class ImageCaptureFileSystem: DeviceFileSystem {
    static let storageID: UInt32 = 1
    /// Bytes per read request; downloads are a series of ranged reads.
    static let readChunkSize = 8 << 20

    let deviceID: DeviceID
    let generation: UInt64
    let isMock = false
    let capabilities = FileSystemCapabilities(canWrite: false, canRename: false, canMoveNatively: false,
                                              canCopyNatively: false, canThumbnail: true, canReadPartially: true,
                                              allowsDeleteWithoutWrite: true)
    private let backend: CameraBackend
    private let storageName: String

    init(deviceID: DeviceID, generation: UInt64, backend: CameraBackend, storageName: String) {
        self.deviceID = deviceID
        self.generation = generation
        self.backend = backend
        self.storageName = storageName
    }

    var storage: StorageInfo {
        StorageInfo(id: Self.storageID, name: storageName, capacity: nil, freeSpace: nil, kind: .internalStorage)
    }

    func storages() async throws(DeviceError) -> [StorageInfo] { [storage] }

    func contents(of folder: FileItemID) async throws(DeviceError) -> [FileItem] {
        try await backend.catalog().filter { $0.parentID == folder.objectID }.map(fileItem)
    }

    func childCount(of folder: FileItemID) async throws(DeviceError) -> Int {
        try await backend.catalog().count { $0.parentID == folder.objectID }
    }

    func item(_ id: FileItemID) async throws(DeviceError) -> FileItem {
        guard !id.isStorageRoot else { throw .objectNotFound }
        guard let entry = try await backend.catalog().first(where: { $0.id == id.objectID }) else { throw .objectNotFound }
        return fileItem(entry)
    }

    func download(_ id: FileItemID, to fileURL: URL, progress: TransferProgress) async throws(DeviceError) {
        let entry = try await item(id)
        guard !entry.isFolder else { throw .unsupportedOperation }
        let size = entry.size ?? 0
        let fd = try LocalFileIO.openForWriting(fileURL)
        defer { close(fd) }
        var received: UInt64 = 0
        progress.update(completed: 0, total: size)
        while received < size {
            if progress.isCancelled { throw .cancelled }
            let length = Int(min(UInt64(Self.readChunkSize), size - received))
            let data = try await backend.read(id.objectID, offset: received, length: length)
            guard !data.isEmpty else { throw .verificationFailed(expected: size, actual: received) }
            try LocalFileIO.writeAll(fd, data, url: fileURL)
            received += UInt64(data.count)
            progress.update(completed: received, total: size)
        }
        guard fsync(fd) == 0 else { throw LocalFileIO.mapErrno(errno, url: fileURL, writing: true) }
    }

    /// Folders (DCIM/100APPLE) are iOS's own; they go away when emptied.
    func delete(_ id: FileItemID) async throws(DeviceError) {
        let catalog = try await backend.catalog()
        guard let entry = catalog.first(where: { $0.id == id.objectID }) else { throw .objectNotFound }
        if entry.isFolder {
            if catalog.contains(where: { $0.parentID == entry.id }) { throw .folderNotEmpty }
            return
        }
        try await backend.delete([entry.id])
    }

    func thumbnail(_ id: FileItemID) async throws(DeviceError) -> Data {
        try await backend.thumbnail(id.objectID)
    }

    func read(_ id: FileItemID, offset: UInt64, length: Int) async throws(DeviceError) -> Data {
        guard length > 0 else { return Data() }
        return try await backend.read(id.objectID, offset: offset, length: length)
    }

    // iOS camera roll: no writing.
    func upload(from fileURL: URL, size: UInt64, named name: String, into folder: FileItemID, modified: Date?,
                progress: TransferProgress) async throws(DeviceError) -> FileItem { throw .unsupportedOperation }
    func createFolder(named name: String, in folder: FileItemID) async throws(DeviceError) -> FileItem { throw .unsupportedOperation }
    func rename(_ id: FileItemID, to name: String) async throws(DeviceError) -> FileItem { throw .unsupportedOperation }
    func move(_ id: FileItemID, to folder: FileItemID) async throws(DeviceError) -> FileItem { throw .unsupportedOperation }
    func copy(_ id: FileItemID, to folder: FileItemID) async throws(DeviceError) -> FileItem { throw .unsupportedOperation }

    private func fileItem(_ entry: CameraEntry) -> FileItem {
        FileItem(id: FileItemID(deviceID: deviceID, storageID: Self.storageID, objectID: entry.id),
                 name: FileNameRules.singleComponent(entry.name), isFolder: entry.isFolder,
                 size: entry.isFolder ? nil : entry.size, modified: entry.modified)
    }
}
