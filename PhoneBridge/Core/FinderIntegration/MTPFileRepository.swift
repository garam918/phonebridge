import Foundation

extension DeviceError {
    /// errno handed to FSKit (and from there to Finder).
    var posixCode: Int32 {
        switch self {
        case .objectNotFound: ENOENT
        case .disconnected, .noMTPInterface: ENXIO
        case .deviceBusy: EBUSY
        case .accessDenied, .localPermissionDenied: EACCES
        case .readOnlyStorage: EROFS
        case .unsupportedOperation: ENOTSUP
        case .storageFull, .insufficientDeviceSpace, .insufficientLocalSpace: ENOSPC
        case .cancelled: ECANCELED
        case .timeout: ETIMEDOUT
        case .invalidName: EINVAL
        case .nameConflict: EEXIST
        case .folderNotEmpty: ENOTEMPTY
        case .crossFolderMoveUnsupported: EXDEV
        case .outOfMemory: ENOMEM
        default: EIO
        }
    }
}

/// "MTP File Repository" of the Finder path: answers FSKit requests with the
/// DeviceBroker's existing session (or the demo device). Writes (2단계) go
/// through `FinderWriteCoordinator` and only when `allowsWrites` is on.
@MainActor
final class MTPFileRepository {
    struct Volume: Identifiable, Hashable, Sendable {
        let address: VolumeAddress
        let deviceName: String
        let storageName: String
        let isDemo: Bool

        var id: String { "\(address.deviceID)|\(address.storageID)" }
        var displayName: String { "\(deviceName) – \(storageName)" }
    }

    private let broker: DeviceBroker
    private let demoDevice: MockDeviceFileSystem
    private let demoName: () -> String
    private let cacheDirectory: URL
    /// Whole-file downloads for devices without partial reads, deduplicated.
    private var cachedFiles: [String: Task<URL, any Error>] = [:]
    var includeDemoDevice = true
    /// Settings › Finder › "Finder에서 쓰기 허용(실험적)"; off by default.
    var allowsWrites = false
    /// Until the real-device check (W5) only the demo device takes writes.
    var allowsRealDeviceWrites = false
    /// W5 diagnostics: real-device writes only inside this root folder.
    var realDeviceWriteScope: String?
    /// W5 diagnostics: list hidden staging/backup objects so leftovers can be seen.
    var showsTemporaryObjects = false
    let writes: FinderWriteCoordinator
    /// A commit failed; its buffer may need recovery (W3).
    var onWriteFailure: (() -> Void)?

    init(broker: DeviceBroker, demoDevice: MockDeviceFileSystem, demoName: @escaping () -> String,
         cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "FinderReadCache", directoryHint: .isDirectory),
         writes: FinderWriteCoordinator = FinderWriteCoordinator(bufferDirectory: FinderIPC.defaultWriteBufferDirectory())) {
        self.broker = broker
        self.demoDevice = demoDevice
        self.demoName = demoName
        self.cacheDirectory = cacheDirectory
        self.writes = writes
    }

    /// Everything that can be mounted right now.
    func mountableVolumes(demoStorages: [StorageInfo]) -> [Volume] {
        var result: [Volume] = []
        for record in broker.devices where record.state.isMTPReady {
            for storage in record.storages {
                result.append(Volume(address: VolumeAddress(deviceID: record.id.volumeKey, storageID: storage.id,
                                                            generation: record.generation),
                                     deviceName: record.displayName, storageName: storage.name, isDemo: false))
            }
        }
        if includeDemoDevice {
            for storage in demoStorages {
                result.append(Volume(address: VolumeAddress(deviceID: DeviceID.demo.rawValue, storageID: storage.id,
                                                            generation: demoDevice.generation),
                                     deviceName: demoName(), storageName: storage.name, isDemo: true))
            }
        }
        return result
    }

    func handle(_ request: FinderRequest) async -> (FinderResponse, Data) {
        do throws(FinderIPCError) {
            switch request {
            case .hello:
                return (.hello(version: FinderIPC.protocolVersion), Data())
            case .describe(let address):
                return (.volume(try await describe(address)), Data())
            case .list(let address, let parent):
                return (.entries(try await list(address, parent: parent)), Data())
            case .stat(let address, let object):
                return (.entry(try await stat(address, object: object)), Data())
            case .read(let address, let object, let offset, let length):
                let data = try await read(address, object: object, offset: offset, length: length)
                return (.data(count: data.count), data)
            case .writeCapabilities(let address):
                return (.writeCapabilities(try await writeCapabilities(address)), Data())
            case .createFolder(let address, let parent, let parentPath, let name):
                let (fs, _) = try await writable(address)
                try checkScope(fs, parentPath, rootName: name)
                let item = try await writes.createFolder(named: name, in: folder(fs, address, parent), fileSystem: fs)
                return (.entry(wrote(item, parent: parent, fs: fs)), Data())
            case .commitFile(let address, let commit):
                let (fs, storage) = try await writable(address)
                try checkScope(fs, commit.parentPath)
                let item = try await writes.commit(commit, in: folder(fs, address, commit.parent), freeSpace: storage.freeSpace,
                                                   fileSystem: fs)
                return (.entry(wrote(item, parent: commit.parent, fs: fs)), Data())
            case .rename(let address, let object, let parent, let parentPath, let name, let replacing):
                let (fs, _) = try await writable(address)
                try checkScope(fs, parentPath)
                let item = try await writes.rename(folder(fs, address, object), in: folder(fs, address, parent), to: name,
                                                   replacing: replacing, fileSystem: fs)
                return (.entry(wrote(item, parent: parent, fs: fs)), Data())
            case .move(let address, let object, let from, let fromPath, let parent, let parentPath, let name, let replacing):
                let (fs, _) = try await writable(address)
                if fromPath == [] || parentPath == [], realDeviceWriteScope != nil, !fs.isMock {
                    // The root-move check (W5 review): only a test file in or out of the root.
                    let moving = try await call { () throws(DeviceError) in
                        try await fs.item(FileItemID(deviceID: fs.deviceID, storageID: address.storageID, objectID: object))
                    }
                    try checkScope(fs, fromPath, rootFile: moving.isFolder ? nil : moving.name)
                    try checkScope(fs, parentPath, rootFile: moving.isFolder ? nil : name)
                } else {
                    try checkScope(fs, fromPath)
                    try checkScope(fs, parentPath)
                }
                let item = try await writes.move(folder(fs, address, object), from: folder(fs, address, from),
                                                 to: folder(fs, address, parent), name: name, replacing: replacing, fileSystem: fs)
                return (.entry(wrote(item, parent: parent, fs: fs)), Data())
            case .delete(let address, let object, let parent, let parentPath):
                let (fs, _) = try await writable(address)
                if parentPath == [], realDeviceWriteScope != nil, !fs.isMock {
                    // Only the test folder itself may go at the root.
                    let target = try await call { () throws(DeviceError) in
                        try await fs.item(FileItemID(deviceID: fs.deviceID, storageID: address.storageID, objectID: object))
                    }
                    try checkScope(fs, parentPath, rootName: target.name, rootFile: target.isFolder ? nil : target.name)
                } else {
                    try checkScope(fs, parentPath)
                }
                try await writes.delete(folder(fs, address, object), in: folder(fs, address, parent), path: parentPath, fileSystem: fs)
                invalidateCache(deviceID: fs.deviceID.volumeKey)
                return (.done, Data())
            }
        } catch {
            if case .commitFile = request { onWriteFailure?() }
            return (.failure(error), Data())
        }
    }

    // MARK: - Operations

    func describe(_ address: VolumeAddress) async throws(FinderIPCError) -> VolumeDescription {
        let fs = try fileSystem(for: address)
        let storages = try await call { () throws(DeviceError) in try await fs.storages() }
        guard let storage = storages.first(where: { $0.id == address.storageID }) else {
            throw FinderIPCError(code: ENOENT, message: "storage not found")
        }
        let record = fs.isMock ? nil : broker.record(for: fs.deviceID)
        let deviceName = fs.isMock ? demoName() : (record?.displayName ?? fs.deviceID.rawValue)
        let name = "\(deviceName) – \(storage.name)"
        // Mount points must be ASCII: "PhoneBridge SM-S937N", "… 2" for the second storage.
        let index = storages.firstIndex { $0.id == storage.id } ?? 0
        let model = fs.isMock ? "Demo" : (record?.info?.model ?? "Android")
        let mountName = VolumeDescription.mountSafeName(name, fallback: "PhoneBridge \(model)" + (index > 0 ? " \(index + 1)" : ""))
        return VolumeDescription(name: name, mountName: mountName, capacity: storage.capacity, freeSpace: storage.freeSpace,
                                 isReadOnly: true, canReadPartially: fs.capabilities.canReadPartially, isDemo: fs.isMock)
    }

    func list(_ address: VolumeAddress, parent: UInt32) async throws(FinderIPCError) -> [RemoteEntry] {
        let fs = try fileSystem(for: address)
        let folder = FileItemID(deviceID: fs.deviceID, storageID: address.storageID, objectID: parent)
        let items = try await call { () throws(DeviceError) in try await fs.contents(of: folder) }
        return items.filter { showsTemporaryObjects || !FileNameRules.isTemporary($0.name) }.map { Self.entry($0, parent: parent) }
    }

    func stat(_ address: VolumeAddress, object: UInt32) async throws(FinderIPCError) -> RemoteEntry {
        if object == remoteRootObjectID {
            return RemoteEntry(objectID: remoteRootObjectID, parentID: remoteRootObjectID, name: "", isFolder: true, size: 0, modified: nil)
        }
        let fs = try fileSystem(for: address)
        let item = try await call { () throws(DeviceError) in
            try await fs.item(FileItemID(deviceID: fs.deviceID, storageID: address.storageID, objectID: object))
        }
        return Self.entry(item, parent: remoteRootObjectID)
    }

    /// Range read. Devices with GetPartialObject are read directly; others
    /// are downloaded once into the cache (staged and size-verified).
    func read(_ address: VolumeAddress, object: UInt32, offset: UInt64, length: Int) async throws(FinderIPCError) -> Data {
        guard length > 0 else { return Data() }
        let length = min(length, FinderIPC.maxBodySize)
        let fs = try fileSystem(for: address)
        let id = FileItemID(deviceID: fs.deviceID, storageID: address.storageID, objectID: object)
        if fs.capabilities.canReadPartially {
            return try await call { () throws(DeviceError) in try await fs.read(id, offset: offset, length: length) }
        }
        let item = try await call { () throws(DeviceError) in try await fs.item(id) }
        let url = try await cachedCopy(of: item, address: address, fileSystem: fs)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            throw FinderIPCError(code: EIO, message: "cache read: \(error.publicSummary)")
        }
    }

    // MARK: - Writes

    func writeCapabilities(_ address: VolumeAddress) async throws(FinderIPCError) -> WriteCapabilities {
        let fs = try fileSystem(for: address)
        let storages = try await call { () throws(DeviceError) in try await fs.storages() }
        let storage = storages.first { $0.id == address.storageID }
        let allowed = allowsWrites && (fs.isMock || allowsRealDeviceWrites) && fs.capabilities.canWrite
            && storage.map { !$0.isReadOnly } == true
        return WriteCapabilities(allowsWrites: allowed, canRename: allowed && fs.capabilities.canRename,
                                 canMove: allowed && fs.capabilities.canMoveNatively)
    }

    /// The volume's file system when writes are allowed, plus its storage.
    private func writable(_ address: VolumeAddress) async throws(FinderIPCError) -> (any DeviceFileSystem, StorageInfo) {
        guard allowsWrites else { throw FinderIPCError(code: EROFS, message: "Finder writes are turned off") }
        let fs = try fileSystem(for: address)
        guard fs.isMock || allowsRealDeviceWrites else {
            throw FinderIPCError(code: EROFS, message: "Finder writes to real devices are not enabled yet")
        }
        let storages = try await call { () throws(DeviceError) in try await fs.storages() }
        guard let storage = storages.first(where: { $0.id == address.storageID }) else {
            throw FinderIPCError(code: ENOENT, message: "storage not found")
        }
        guard fs.capabilities.canWrite, !storage.isReadOnly else { throw FinderIPCError(code: EROFS, message: "read-only storage") }
        return (fs, storage)
    }

    /// W5 guard: on real devices, with a scope set, writes must happen inside
    /// the scope folder. At the root only the folder itself may be created or
    /// deleted (`rootName`), and only a *file* whose name starts with the
    /// folder's name may be moved in or out (`rootFile`, root-move check).
    /// Unknown paths are refused.
    private func checkScope(_ fs: any DeviceFileSystem, _ path: [String]?, rootName: String? = nil,
                            rootFile: String? = nil) throws(FinderIPCError) {
        guard !fs.isMock, let scope = realDeviceWriteScope else { return }
        if let path, path.first == scope { return }
        if path == [], rootName == scope { return }
        if path == [], let rootFile, rootFile.hasPrefix(scope), rootFile != scope { return }
        throw FinderIPCError(code: EACCES, message: "outside the test folder \(scope)")
    }

    private func folder(_ fs: any DeviceFileSystem, _ address: VolumeAddress, _ objectID: UInt32) -> FileItemID {
        FileItemID(deviceID: fs.deviceID, storageID: address.storageID, objectID: objectID)
    }

    /// Entry for a written item; cached reads of the device are dropped.
    private func wrote(_ item: FileItem, parent: UInt32, fs: any DeviceFileSystem) -> RemoteEntry {
        invalidateCache(deviceID: fs.deviceID.volumeKey)
        return Self.entry(item, parent: parent)
    }

    /// Drops cached copies of a device (new session, or files changed).
    func invalidateCache(deviceID: String? = nil) {
        let prefix = deviceID.map(Self.cachePrefix)
        for key in cachedFiles.keys where prefix == nil || key.hasPrefix(prefix!) {
            cachedFiles[key]?.cancel()
            cachedFiles[key] = nil
        }
        if let prefix {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
            for name in names where name.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: cacheDirectory.appending(path: name))
            }
        } else {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    var cachedFileCount: Int { cachedFiles.count }

    // MARK: - Helpers

    /// The device behind a volume address (`DeviceID.volumeKey`), if connected.
    func deviceID(forVolumeKey key: String) -> DeviceID? {
        if key == DeviceID.demo.rawValue { return .demo }
        return broker.devices.first { $0.id.volumeKey == key }?.id
    }

    private func fileSystem(for address: VolumeAddress) throws(FinderIPCError) -> any DeviceFileSystem {
        let deviceID = deviceID(forVolumeKey: address.deviceID)
        let fs: (any DeviceFileSystem)? = deviceID == .demo ? (includeDemoDevice ? demoDevice : nil)
            : deviceID.flatMap { broker.fileSystem(for: $0) }
        guard let fs else { throw FinderIPCError(code: ENXIO, message: "device not connected") }
        // Handles from an older session are meaningless: force a remount.
        guard fs.generation == address.generation else { throw FinderIPCError(code: ESTALE, message: "session changed") }
        return fs
    }

    private func cachedCopy(of item: FileItem, address: VolumeAddress, fileSystem fs: any DeviceFileSystem) async throws(FinderIPCError) -> URL {
        let key = Self.cachePrefix(address.deviceID)
            + "\(address.generation)-\(item.id.storageID)-\(item.id.objectID)-\(item.size ?? 0)-\(Int(item.modified?.timeIntervalSince1970 ?? 0))"
        let task: Task<URL, any Error>
        if let existing = cachedFiles[key] {
            task = existing
        } else {
            let directory = cacheDirectory
            task = Task {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let final = directory.appending(path: key)
                if FileManager.default.fileExists(atPath: final.path) { return final }
                let staging = directory.appending(path: FileNameRules.temporaryName(suffix: "cache"))
                do {
                    try await fs.download(item.id, to: staging, progress: TransferProgress())
                    if let expected = item.size, LocalFileIO.fileSize(staging) != expected {
                        throw DeviceError.verificationFailed(expected: expected, actual: LocalFileIO.fileSize(staging) ?? 0)
                    }
                    try FileManager.default.moveItem(at: staging, to: final)
                    return final
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
            }
            cachedFiles[key] = task
        }
        do {
            return try await task.value
        } catch {
            cachedFiles[key] = nil
            if let deviceError = error as? DeviceError {
                throw FinderIPCError(code: deviceError.posixCode, message: deviceError.localizationKey)
            }
            throw FinderIPCError(code: EIO, message: "upload buffer: \(error.publicSummary)")
        }
    }

    private func call<T>(_ body: () async throws(DeviceError) -> T) async throws(FinderIPCError) -> T {
        do {
            return try await body()
        } catch {
            throw FinderIPCError(code: error.posixCode, message: error.localizationKey)
        }
    }

    private static func cachePrefix(_ deviceID: String) -> String {
        // File-name safe, stable per device.
        let safe = deviceID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return String(safe) + "-"
    }

    static func entry(_ item: FileItem, parent: UInt32) -> RemoteEntry {
        RemoteEntry(objectID: item.id.objectID, parentID: parent, name: item.name, isFolder: item.isFolder,
                    size: item.isFolder ? 0 : (item.size ?? 0), modified: item.modified?.timeIntervalSince1970)
    }
}
