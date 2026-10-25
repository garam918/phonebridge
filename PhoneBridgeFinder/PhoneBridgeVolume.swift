import Foundation
import FSKit
import os

let writeLog = Logger(subsystem: FinderIPC.extensionBundleIdentifier, category: "writes")

/// One device object, or a file that so far exists only in the extension
/// (`objectID == 0`; MTP never uses handle 0).
final class PhoneBridgeItem: FSItem, @unchecked Sendable {
    // Guarded by the volume's lock.
    var objectID: UInt32
    var entry: RemoteEntry
    var parentObjectID: UInt32
    /// Stable for the life of this item, also across the first upload.
    let fileIdentifier: FSItem.Identifier

    /// Local copy holding the bytes: new files, edits in progress, shadow files.
    var bufferName: String?
    /// Lock held on the buffer while this extension uses it (`WriteBufferLock`).
    var bufferLock: Int32 = -1
    var isDirty = false
    var isOpenForWriting = false
    /// Device object a local file will replace (renamed over it before upload).
    var replacing: UInt32?
    var delayedCommit: DispatchWorkItem?
    /// Kept in memory only: the device has no extended attributes.
    var xattrs: [String: Data] = [:]

    init(entry: RemoteEntry, parent: UInt32, identifier: FSItem.Identifier) {
        objectID = entry.objectID
        self.entry = entry
        parentObjectID = parent
        fileIdentifier = identifier
        super.init()
    }

    var isRoot: Bool { objectID == remoteRootObjectID }
    var isLocal: Bool { objectID == 0 }
    var isShadow: Bool { FinderWritePolicy.isShadowName(entry.name) }
}

/// FSKit volume backed by the PhoneBridge app's MTP repository.
///
/// Read-only unless the app reports `WriteCapabilities.allowsWrites`. With
/// writes, files are written to a local buffer in the App Group container and
/// uploaded by the app when the last writer closes them (FINDER_WRITE_PLAN.md,
/// W0 results); macOS bookkeeping files (`._*`, `.DS_Store`) and extended
/// attributes stay in the extension.
final class PhoneBridgeVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations,
    FSVolume.OpenCloseOperations, FSVolume.PreallocateOperations, FSVolume.XattrOperations, @unchecked Sendable {
    private let address: VolumeAddress
    private let client: FinderBrokerClient
    /// Separate connection so long uploads do not hold up Finder's reads.
    private let writeClient: FinderBrokerClient
    private let volumeDescription: VolumeDescription
    private let writable: Bool
    private let bufferDirectory: URL?
    /// Hidden staging/backup objects are listed only on diagnostic mounts.
    private let showsStagingObjects: Bool
    private let root: PhoneBridgeItem
    private let lock = NSLock()
    private var items: [UInt32: PhoneBridgeItem] = [:]
    /// Files that exist only here, by parent folder.
    private var localItems: [UInt32: [PhoneBridgeItem]] = [:]
    /// Device objects hidden because a local file was renamed over them.
    private var hiddenObjects: Set<UInt32> = []
    private var listings: [UInt32: (entries: [RemoteEntry], fetched: Date)] = [:]
    private var nextLocalID: UInt64 = 0
    private let queue = DispatchQueue(label: "PhoneBridge.FinderVolume", qos: .userInitiated, attributes: .concurrent)
    private static let listingLifetime: TimeInterval = 3
    private static let maximumXattrBytes = 128 << 10

    init(address: VolumeAddress, description: VolumeDescription, client: FinderBrokerClient, writeClient: FinderBrokerClient,
         writable: Bool, bufferDirectory: URL?, showsStagingObjects: Bool = false) {
        self.address = address
        self.client = client
        self.writeClient = writeClient
        volumeDescription = description
        self.writable = writable && bufferDirectory != nil
        self.bufferDirectory = bufferDirectory
        self.showsStagingObjects = showsStagingObjects
        root = PhoneBridgeItem(entry: RemoteEntry(objectID: remoteRootObjectID, parentID: remoteRootObjectID, name: "",
                                                  isFolder: true, size: 0, modified: nil),
                               parent: remoteRootObjectID, identifier: .rootDirectory)
        super.init(volumeID: FSVolume.Identifier(uuid: address.uuid),
                   volumeName: FSFileName(string: description.mountName ?? description.name))
        if let bufferDirectory, self.writable {
            try? FileManager.default.createDirectory(at: bufferDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Volume properties

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsHiddenFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.supports2TBFiles = true
        capabilities.doesNotSupportSettingFilePermissions = true
        capabilities.doesNotSupportImmutableFiles = true
        capabilities.caseFormat = .insensitiveCasePreserving
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: Self.fileSystemTypeName)
        let blockSize: UInt64 = 4096
        let total = volumeDescription.capacity ?? 0
        let free = volumeDescription.freeSpace ?? 0
        result.blockSize = Int(blockSize)
        result.ioSize = 1 << 20
        result.totalBytes = total
        result.availableBytes = free
        result.freeBytes = free
        result.usedBytes = total >= free ? total - free : 0
        result.totalBlocks = total / blockSize
        result.availableBlocks = free / blockSize
        result.freeBlocks = free / blockSize
        result.usedBlocks = result.usedBytes / blockSize
        return result
    }

    /// This build's FSShortName (`phonebridge`, `phonebridgedev`), so release
    /// and development builds can tell their volumes apart.
    private static let fileSystemTypeName: String = {
        let attributes = Bundle.main.object(forInfoDictionaryKey: "EXAppExtensionAttributes") as? [String: Any]
        return attributes?["FSShortName"] as? String ?? FinderIPC.urlScheme
    }()

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { writable ? Self.maximumXattrBytes : 0 }
    var maximumXattrSizeInBits: Int { writable ? 18 : 0 }
    var maximumFileSize: UInt64 { UInt64.max }
    var maximumFileSizeInBits: Int { 64 }

    // Optional operation sets are only offered on writable volumes, so a
    // read-only volume behaves exactly as before.
    var isOpenCloseInhibited: Bool {
        get { !writable }
        set {}
    }

    var isPreallocateInhibited: Bool {
        get { !writable }
        set {}
    }

    var xattrOperationsInhibited: Bool {
        get { !writable }
        set {}
    }

    // MARK: - Lifecycle

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
        // The mount point already exists under the ASCII name; show the real
        // (Korean) name from now on.
        if volumeDescription.mountName != nil, volumeDescription.mountName != volumeDescription.name {
            name = FSFileName(string: volumeDescription.name)
        }
        if writable { writeLog.info("mounted with Finder writes enabled") }
        ExtensionStatusRecorder.shared.record("mounted", writable ? "writable" : "read-only", mountedChange: 1)
    }

    /// Buffers of real files that never reached the device stay, unlocked,
    /// for the app to offer back (W3); shadow files go.
    func unmount(replyHandler reply: @escaping () -> Void) {
        let held: [PhoneBridgeItem] = lock.withLock { Array(items.values) + localItems.values.flatMap { $0 } }
        for item in held where lock.withLock({ item.bufferName != nil }) {
            if item.isShadow || !lock.withLock({ item.isDirty || item.isLocal }) {
                dropBuffer(of: item)
            } else {
                lock.withLock {
                    WriteBufferLock.release(item.bufferLock)
                    item.bufferLock = -1
                }
                writeLog.info("unmounted with an unsaved file; the app offers it for recovery")
                ExtensionStatusRecorder.shared.record("unsaved-file", "kept for recovery")
            }
        }
        ExtensionStatusRecorder.shared.record("unmounted", mountedChange: -1)
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        reply(root, nil)
    }

    func deactivate(options: FSDeactivateOptions = [], replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        if let item = item as? PhoneBridgeItem, !item.isRoot {
            lock.withLock {
                // Local files live on in `localItems`; edits in progress stay.
                if !item.isLocal, item.bufferName == nil, items[item.objectID] === item {
                    items[item.objectID] = nil
                }
            }
        }
        reply(nil)
    }

    // MARK: - Lookup and listing

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let directory = directory as? PhoneBridgeItem, let wanted = name.string else {
            reply(nil, nil, posixError(ENOENT))
            return
        }
        queue.async { [self] in
            do throws(FinderIPCError) {
                guard let match = try child(named: wanted, in: directory) else {
                    reply(nil, nil, posixError(ENOENT))
                    return
                }
                reply(match, FSFileName(string: match.entry.name), nil)
            } catch {
                reply(nil, nil, error.fsError)
            }
        }
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        guard let directory = directory as? PhoneBridgeItem else {
            reply(verifier, posixError(ENOTDIR))
            return
        }
        queue.async { [self] in
            do throws(FinderIPCError) {
                let children = try contents(of: directory, forceRefresh: cookie == .initial)
                let current = FSDirectoryVerifier(rawValue: Self.verifier(for: lock.withLock { children.map(\.entry) }))
                // readdir() (attributes == nil) also needs "." and "..".
                var rows: [(name: String, item: PhoneBridgeItem?, isDot: Bool)] = []
                if attributes == nil {
                    rows.append((".", nil, true))
                    rows.append(("..", nil, true))
                }
                rows += lock.withLock { children.map { ($0.entry.name, $0, false) } }
                var index = Int(cookie.rawValue)
                while index < rows.count {
                    let row = rows[index]
                    let next = FSDirectoryCookie(rawValue: UInt64(index + 1))
                    let packed: Bool
                    if row.isDot {
                        let id = row.name == "." ? directory.fileIdentifier : identifier(forObject: directory.parentObjectID)
                        packed = packer.packEntry(name: FSFileName(string: row.name), itemType: .directory, itemID: id,
                                                  nextCookie: next, attributes: nil)
                    } else if let item = row.item {
                        let attrs = attributes.map { _ in self.attributes(for: item) }
                        packed = packer.packEntry(name: FSFileName(string: row.name), itemType: item.entry.isFolder ? .directory : .file,
                                                  itemID: item.fileIdentifier, nextCookie: next, attributes: attrs)
                    } else {
                        packed = true
                    }
                    if !packed { break }
                    index += 1
                }
                reply(current, nil)
            } catch {
                reply(verifier, error.fsError)
            }
        }
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? PhoneBridgeItem else {
            reply(nil, posixError(ENOENT))
            return
        }
        reply(attributes(for: item), nil)
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, posixError(EINVAL))
    }

    // MARK: - Read

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        guard let item = item as? PhoneBridgeItem, !item.entry.isFolder else {
            reply(0, posixError(EISDIR))
            return
        }
        let wanted = min(length, buffer.length)
        let (size, local, objectID) = lock.withLock { (item.entry.size, item.bufferName.flatMap(bufferURL), item.objectID) }
        guard offset >= 0, wanted > 0, UInt64(offset) < size else {
            reply(0, nil)
            return
        }
        queue.async { [self] in
            do throws(FinderIPCError) {
                let data: Data
                if let local {
                    data = try Self.readLocal(local, offset: UInt64(offset), length: wanted)
                } else {
                    data = try client.read(address, object: objectID, offset: UInt64(offset), length: wanted)
                }
                let count = min(data.count, wanted)
                _ = buffer.withUnsafeMutableBytes { destination in
                    data.copyBytes(to: destination.bindMemory(to: UInt8.self), count: count)
                }
                reply(count, nil)
            } catch {
                reply(0, error.fsError)
            }
        }
    }

    // MARK: - Write

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        guard writable, let item = item as? PhoneBridgeItem, !item.entry.isFolder, offset >= 0 else {
            reply(0, posixError(writable ? EINVAL : EROFS))
            return
        }
        queue.async { [self] in
            do throws(FinderIPCError) {
                let url = try ensureBuffer(item, keepContents: true)
                let size = try Self.writeLocal(contents, to: url, at: UInt64(offset))
                lock.withLock {
                    // Writes never shrink a file; concurrent writes may finish out of order.
                    item.entry.size = max(item.entry.size, size)
                    item.entry.modified = Date().timeIntervalSince1970
                    item.isDirty = true
                    item.delayedCommit?.cancel()
                    item.delayedCommit = nil
                }
                reply(contents.count, nil)
            } catch {
                writeLog.error("write failed: \(error.code) \(error.message, privacy: .public)")
                ExtensionStatusRecorder.shared.record("write-failed", "\(error.code) \(error.message)")
                reply(0, error.fsError)
            }
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard writable, let item = item as? PhoneBridgeItem else {
            reply(nil, posixError(EROFS))
            return
        }
        queue.async { [self] in
            if newAttributes.isValid(.size), !item.entry.isFolder {
                do throws(FinderIPCError) {
                    let size = newAttributes.size
                    let unchanged = lock.withLock { item.entry.size == size && !item.isLocal && item.bufferName == nil }
                    if !unchanged {
                        let url = try ensureBuffer(item, keepContents: size > 0)
                        try Self.truncateLocal(url, to: size)
                        lock.withLock {
                            item.entry.size = size
                            item.isDirty = true
                        }
                    }
                } catch {
                    reply(nil, error.fsError)
                    return
                }
            }
            if newAttributes.isValid(.modifyTime) {
                // Shown until the next listing; the device keeps its own time.
                let time = newAttributes.modifyTime
                lock.withLock { item.entry.modified = Double(time.tv_sec) + Double(time.tv_nsec) / 1e9 }
            }
            // Permissions, owners, flags and other times cannot be stored on
            // the device; accepting them keeps Finder's copy going (W0).
            newAttributes.consumedAttributes = Self.requested(newAttributes)
            reply(attributes(for: item), nil)
        }
    }

    func preallocateSpace(for item: FSItem, at offset: off_t, length: Int, flags: FSVolume.PreallocateFlags,
                          replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        reply(writable ? length : 0, writable ? nil : posixError(EROFS))
    }

    // MARK: - Open / close (upload on the last close)

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        if let item = item as? PhoneBridgeItem, !item.entry.isFolder, modes.contains(.write) {
            lock.withLock {
                item.isOpenForWriting = true
                item.delayedCommit?.cancel()
                item.delayedCommit = nil
            }
        }
        reply(nil)
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard let item = item as? PhoneBridgeItem, !item.entry.isFolder else {
            reply(nil)
            return
        }
        let action: FinderWritePolicy.CloseAction = lock.withLock {
            guard item.isOpenForWriting else { return .none }
            // `modes` are the modes still open after this close.
            let stillWriting = modes.contains(.write)
            item.isOpenForWriting = stillWriting
            return FinderWritePolicy.closeAction(writersLeft: stillWriting ? 1 : 0, isShadow: item.isShadow, isOnDevice: !item.isLocal,
                                                 isDirty: item.isDirty, size: item.entry.size)
        }
        switch action {
        case .none:
            reply(nil)
        case .commit:
            queue.async { [self] in
                do throws(FinderIPCError) {
                    try commit(item)
                    reply(nil)
                } catch {
                    reply(error.fsError)
                }
            }
        case .commitLater:
            let work = DispatchWorkItem { [weak self, weak item] in
                guard let self, let item else { return }
                let stillWanted = self.lock.withLock { item.isLocal && !item.isOpenForWriting && item.delayedCommit != nil }
                guard stillWanted else { return }
                do throws(FinderIPCError) {
                    try self.commit(item)
                } catch {
                    writeLog.error("creating an empty file failed: \(error.code) \(error.message, privacy: .public)")
                    ExtensionStatusRecorder.shared.record("create-failed", "\(error.code) \(error.message)")
                }
            }
            lock.withLock { item.delayedCommit = work }
            queue.asyncAfter(deadline: .now() + FinderWritePolicy.emptyFileDelay, execute: work)
            reply(nil)
        }
    }

    // MARK: - Create, rename, remove

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard writable, let directory = directory as? PhoneBridgeItem, let text = name.string else {
            reply(nil, nil, posixError(EROFS))
            return
        }
        guard type == .file || type == .directory else {
            reply(nil, nil, posixError(ENOTSUP))
            return
        }
        queue.async { [self] in
            do throws(FinderIPCError) {
                if try child(named: text, in: directory) != nil { throw FinderIPCError(code: EEXIST, message: "exists") }
                if type == .directory {
                    guard !FinderWritePolicy.isRefusedFolderName(text), !FinderWritePolicy.isShadowName(text) else {
                        throw FinderIPCError(code: EACCES, message: "macOS system folder")
                    }
                    let path = lock.withLock { folderPathLocked(directory.objectID) }
                    let entry = try writeClient.createFolder(address, parent: directory.objectID, parentPath: path, name: text)
                    invalidateListing(directory.objectID)
                    reply(item(for: entry, parent: directory.objectID), FSFileName(string: entry.name), nil)
                    return
                }
                let item = try makeLocalFile(named: text, in: directory)
                reply(item, FSFileName(string: text), nil)
            } catch {
                reply(nil, nil, error.fsError)
            }
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName,
                            replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, posixError(writable ? ENOTSUP : EROFS))
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, posixError(writable ? ENOTSUP : EROFS))
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem, overItem: FSItem?,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        guard writable, let item = item as? PhoneBridgeItem, let source = sourceDirectory as? PhoneBridgeItem,
              let target = destinationDirectory as? PhoneBridgeItem, let newName = destinationName.string else {
            reply(nil, posixError(EROFS))
            return
        }
        let over = overItem as? PhoneBridgeItem
        queue.async { [self] in
            do throws(FinderIPCError) {
                // A local file in the way simply goes away.
                if let over, over !== item, lock.withLock({ over.isLocal }) { discardLocal(over) }
                let replacing: UInt32? = over.flatMap { over in lock.withLock { over.isLocal || over === item ? nil : over.objectID } }
                if lock.withLock({ item.isLocal }) {
                    try renameLocal(item, from: source, to: newName, in: target, replacing: replacing)
                } else {
                    try renameOnDevice(item, from: source, to: newName, in: target, replacing: replacing)
                }
                reply(destinationName, nil)
            } catch {
                reply(nil, error.fsError)
            }
        }
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard writable, let item = item as? PhoneBridgeItem, let directory = directory as? PhoneBridgeItem else {
            reply(posixError(EROFS))
            return
        }
        queue.async { [self] in
            if lock.withLock({ item.isLocal }) {
                discardLocal(item)
                reply(nil)
                return
            }
            do throws(FinderIPCError) {
                let objectID = lock.withLock { item.objectID }
                let path = lock.withLock { folderPathLocked(directory.objectID) }
                try writeClient.delete(address, object: objectID, parent: directory.objectID, parentPath: path)
                lock.withLock {
                    if items[objectID] === item { items[objectID] = nil }
                    item.isDirty = false
                }
                dropBuffer(of: item)
                invalidateListing(directory.objectID)
                if item.entry.isFolder { invalidateListing(objectID) }
                reply(nil)
            } catch {
                reply(error.fsError)
            }
        }
    }

    // MARK: - Extended attributes (memory only)

    func getXattr(named name: FSFileName, of item: FSItem, replyHandler reply: @escaping (Data?, (any Error)?) -> Void) {
        guard let item = item as? PhoneBridgeItem, let key = name.string else {
            reply(nil, posixError(EINVAL))
            return
        }
        let value = lock.withLock { item.xattrs[key] }
        reply(value, value == nil ? posixError(ENOATTR) : nil)
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy,
                  replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard writable else {
            reply(posixError(EROFS))
            return
        }
        guard let item = item as? PhoneBridgeItem, let key = name.string else {
            reply(posixError(EINVAL))
            return
        }
        let error: Int32? = lock.withLock {
            let exists = item.xattrs[key] != nil
            switch policy {
            case .mustCreate where exists: return EEXIST
            case .mustReplace where !exists: return ENOATTR
            case .delete:
                guard exists else { return ENOATTR }
                item.xattrs[key] = nil
                return nil
            default:
                guard let value else { return EINVAL }
                guard value.count <= Self.maximumXattrBytes else { return E2BIG }
                item.xattrs[key] = value
                return nil
            }
        }
        reply(error.map(posixError))
    }

    func listXattrs(of item: FSItem, replyHandler reply: @escaping ([FSFileName]?, (any Error)?) -> Void) {
        guard let item = item as? PhoneBridgeItem else {
            reply(nil, posixError(EINVAL))
            return
        }
        reply(lock.withLock { item.xattrs.keys.sorted().map { FSFileName(string: $0) } }, nil)
    }

    // MARK: - Write helpers

    private func bufferURL(_ name: String) -> URL? {
        bufferDirectory?.appending(path: name)
    }

    /// The item's local copy; an existing device file is downloaded first
    /// when its contents are needed (MTP cannot write at an offset).
    private func ensureBuffer(_ item: PhoneBridgeItem, keepContents: Bool) throws(FinderIPCError) -> URL {
        let (existing, objectID, size) = lock.withLock { (item.bufferName, item.objectID, item.entry.size) }
        if let existing, let url = bufferURL(existing) { return url }
        let name = FinderWritePolicy.newBufferName(shadow: item.isShadow)
        guard let url = bufferURL(name) else { throw FinderIPCError(code: EROFS, message: "no buffer folder") }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FinderIPCError(code: EIO, message: "cannot create buffer")
        }
        if keepContents, objectID != 0, size > 0 {
            do throws(FinderIPCError) {
                try download(objectID, size: size, to: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
        let (result, isNew): (URL, Bool) = lock.withLock {
            if let raced = item.bufferName, let racedURL = bufferURL(raced) {
                try? FileManager.default.removeItem(at: url)
                return (racedURL, false)
            }
            item.bufferName = name
            item.bufferLock = WriteBufferLock.acquire(url)
            return (url, true)
        }
        if isNew { updateManifest(item) }
        return result
    }

    private func download(_ objectID: UInt32, size: UInt64, to url: URL) throws(FinderIPCError) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw FinderIPCError(code: EIO, message: "buffer: \(error.publicSummary)")
        }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while offset < size {
            let chunk = try client.read(address, object: objectID, offset: offset, length: 8 << 20)
            if chunk.isEmpty { break }
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                throw FinderIPCError(code: EIO, message: "buffer: \(error.publicSummary)")
            }
            offset += UInt64(chunk.count)
        }
        guard offset == size else { throw FinderIPCError(code: EIO, message: "original changed while copying") }
    }

    /// Sends the local copy to the device and turns the item into a device object.
    private func commit(_ item: PhoneBridgeItem) throws(FinderIPCError) {
        let snapshot: (request: CommitRequest, wasLocal: Bool, oldObject: UInt32)? = lock.withLock {
            guard let bufferName = item.bufferName, !item.isShadow else { return nil }
            item.delayedCommit = nil
            let replacing = item.isLocal ? item.replacing : item.objectID
            return (CommitRequest(parent: item.parentObjectID, parentPath: folderPathLocked(item.parentObjectID), name: item.entry.name,
                                  replacing: replacing, bufferName: bufferName, size: item.entry.size, modified: item.entry.modified),
                    item.isLocal, item.objectID)
        }
        guard let snapshot else { return }
        let started = Date()
        let entry: RemoteEntry
        do throws(FinderIPCError) {
            entry = try writeClient.commitFile(address, snapshot.request)
        } catch {
            // The local copy stays so nothing written is lost; Finder deletes
            // a failed copy itself (W0), which also drops the copy.
            writeLog.error("upload failed: \(error.code) \(error.message, privacy: .public)")
            ExtensionStatusRecorder.shared.record("upload-failed", "\(error.code) \(error.message)")
            updateManifest(item, state: .failed, error: error.message)
            throw error
        }
        lock.withLock {
            if snapshot.wasLocal {
                localItems[snapshot.request.parent]?.removeAll { $0 === item }
            } else if items[snapshot.oldObject] === item {
                items[snapshot.oldObject] = nil
            }
            if let replaced = snapshot.request.replacing {
                hiddenObjects.remove(replaced)
                if let old = items[replaced], old !== item { items[replaced] = nil }
            }
            item.objectID = entry.objectID
            item.entry = entry
            item.replacing = nil
            item.isDirty = false
            items[entry.objectID] = item
        }
        dropBuffer(of: item)
        invalidateListing(snapshot.request.parent)
        writeLog.info("uploaded \(snapshot.request.size) bytes in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public) s")
    }

    private func makeLocalFile(named name: String, in directory: PhoneBridgeItem) throws(FinderIPCError) -> PhoneBridgeItem {
        let bufferName = FinderWritePolicy.newBufferName(shadow: FinderWritePolicy.isShadowName(name))
        guard let url = bufferURL(bufferName), FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FinderIPCError(code: EIO, message: "cannot create buffer")
        }
        let item: PhoneBridgeItem = lock.withLock {
            nextLocalID += 1
            let entry = RemoteEntry(objectID: 0, parentID: directory.objectID, name: name, isFolder: false, size: 0,
                                    modified: Date().timeIntervalSince1970)
            let item = PhoneBridgeItem(entry: entry, parent: directory.objectID, identifier: FSItem.Identifier((1 << 40) + nextLocalID))
            item.bufferName = bufferName
            item.bufferLock = WriteBufferLock.acquire(url)
            localItems[directory.objectID, default: []].append(item)
            return item
        }
        updateManifest(item)
        return item
    }

    private func renameLocal(_ item: PhoneBridgeItem, from source: PhoneBridgeItem, to name: String, in target: PhoneBridgeItem,
                             replacing: UInt32?) throws(FinderIPCError) {
        let commitNow: Bool = lock.withLock {
            localItems[source.objectID]?.removeAll { $0 === item }
            if let previous = item.replacing { hiddenObjects.remove(previous) }
            item.entry.name = name
            item.entry.parentID = target.objectID
            item.parentObjectID = target.objectID
            item.replacing = replacing
            if let replacing { hiddenObjects.insert(replacing) }
            localItems[target.objectID, default: []].append(item)
            // Renamed after its last close (e.g. a shadow name becoming real).
            return !item.isOpenForWriting && !item.isShadow && item.delayedCommit == nil && item.isDirty
        }
        updateManifest(item)
        if commitNow { try commit(item) }
    }

    private func renameOnDevice(_ item: PhoneBridgeItem, from source: PhoneBridgeItem, to name: String, in target: PhoneBridgeItem,
                                replacing: UInt32?) throws(FinderIPCError) {
        let (objectID, sourcePath, targetPath) = lock.withLock {
            (item.objectID, folderPathLocked(source.objectID), folderPathLocked(target.objectID))
        }
        let entry = source.objectID == target.objectID
            ? try writeClient.rename(address, object: objectID, parent: target.objectID, parentPath: targetPath, name: name,
                                     replacing: replacing)
            : try writeClient.move(address, object: objectID, from: source.objectID, fromPath: sourcePath, parent: target.objectID,
                                   parentPath: targetPath, name: name, replacing: replacing)
        lock.withLock {
            if let replacing, let old = items[replacing], old !== item { items[replacing] = nil }
            if items[objectID] === item { items[objectID] = nil }
            item.objectID = entry.objectID
            item.entry.name = entry.name
            item.entry.parentID = target.objectID
            item.parentObjectID = target.objectID
            items[entry.objectID] = item
        }
        if lock.withLock({ item.bufferName != nil }) { updateManifest(item) }
        invalidateListing(source.objectID)
        invalidateListing(target.objectID)
    }

    /// Forgets a file that never reached the device (or a shadow file).
    private func discardLocal(_ item: PhoneBridgeItem) {
        lock.withLock {
            item.delayedCommit?.cancel()
            item.delayedCommit = nil
            localItems[item.parentObjectID]?.removeAll { $0 === item }
            if let replacing = item.replacing { hiddenObjects.remove(replacing) }
            item.replacing = nil
            item.isDirty = false
        }
        dropBuffer(of: item)
    }

    private func dropBuffer(of item: PhoneBridgeItem) {
        let name: String? = lock.withLock {
            defer {
                item.bufferName = nil
                WriteBufferLock.release(item.bufferLock)
                item.bufferLock = -1
            }
            return item.bufferName
        }
        guard let name else { return }
        for file in [name, WriteBufferManifest.manifestName(for: name)] {
            if let url = bufferURL(file) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Writes (or, for shadow files, removes) the buffer's manifest.
    private func updateManifest(_ item: PhoneBridgeItem, state: WriteBufferManifest.State = .writing, error: String? = nil) {
        let snapshot: (buffer: String, name: String?, path: [String])? = lock.withLock {
            guard let buffer = item.bufferName else { return nil }
            return (buffer, item.isShadow ? nil : item.entry.name, folderPathLocked(item.parentObjectID) ?? [])
        }
        guard let snapshot, let url = bufferURL(WriteBufferManifest.manifestName(for: snapshot.buffer)) else { return }
        guard let name = snapshot.name else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let manifest = WriteBufferManifest(bufferName: snapshot.buffer, volume: address, volumeName: volumeDescription.name,
                                           folderPath: snapshot.path, fileName: name, state: state, updated: Date(), lastError: error)
        try? JSONEncoder().encode(manifest).write(to: url, options: .atomic)
    }

    /// Folder names from the storage root; nil when a folder on the way is
    /// no longer known here.
    private func folderPathLocked(_ objectID: UInt32) -> [String]? {
        var names: [String] = []
        var current = objectID
        while current != remoteRootObjectID {
            guard let folder = items[current], names.count < 128 else { return nil }
            names.insert(folder.entry.name, at: 0)
            current = folder.parentObjectID
        }
        return names
    }

    // MARK: - Listing helpers

    private func remoteEntries(of objectID: UInt32, forceRefresh: Bool = false) throws(FinderIPCError) -> [RemoteEntry] {
        if !forceRefresh, let cached = lock.withLock({ listings[objectID] }),
           Date().timeIntervalSince(cached.fetched) < Self.listingLifetime {
            return cached.entries
        }
        let listed = try client.list(address, parent: objectID)
        let entries = showsStagingObjects ? listed : listed.filter { !$0.name.hasPrefix(FinderIPC.temporaryPrefix) }
        lock.withLock { listings[objectID] = (entries, Date()) }
        return entries
    }

    /// Device entries plus local files; a local file hides a device object
    /// of the same name (it is about to replace it).
    private func contents(of directory: PhoneBridgeItem, forceRefresh: Bool = false) throws(FinderIPCError) -> [PhoneBridgeItem] {
        let remote = try remoteEntries(of: directory.objectID, forceRefresh: forceRefresh)
        let (local, hidden, localNames) = lock.withLock {
            let local = localItems[directory.objectID] ?? []
            return (local, hiddenObjects, Set(local.map { $0.entry.name.lowercased() }))
        }
        let visible = remote.filter { !hidden.contains($0.objectID) && !localNames.contains($0.name.lowercased()) }
        return visible.map { item(for: $0, parent: directory.objectID) } + local
    }

    private func child(named name: String, in directory: PhoneBridgeItem) throws(FinderIPCError) -> PhoneBridgeItem? {
        let children = try contents(of: directory)
        let names = lock.withLock { children.map(\.entry.name) }
        if let exact = names.firstIndex(of: name) { return children[exact] }
        return names.firstIndex { $0.compare(name, options: [.caseInsensitive]) == .orderedSame }.map { children[$0] }
    }

    private func invalidateListing(_ objectID: UInt32) {
        _ = lock.withLock { listings.removeValue(forKey: objectID) }
    }

    private func item(for entry: RemoteEntry, parent: UInt32) -> PhoneBridgeItem {
        lock.withLock {
            if let existing = items[entry.objectID] {
                // An edit in progress keeps its own size and time.
                if existing.bufferName == nil {
                    if existing.entry.size != entry.size, !existing.entry.isFolder {
                        writeLog.info("listing changed a size: \(existing.entry.size) → \(entry.size) object \(entry.objectID) \(entry.name, privacy: .private) (was \(existing.entry.name, privacy: .private))")
                    }
                    existing.entry = entry
                }
                existing.parentObjectID = parent
                return existing
            }
            let item = PhoneBridgeItem(entry: entry, parent: parent, identifier: identifierLocked(forObject: entry.objectID))
            items[entry.objectID] = item
            return item
        }
    }

    private func identifier(forObject objectID: UInt32) -> FSItem.Identifier {
        lock.withLock { identifierLocked(forObject: objectID) }
    }

    private func identifierLocked(forObject objectID: UInt32) -> FSItem.Identifier {
        if objectID == remoteRootObjectID { return .rootDirectory }
        return items[objectID]?.fileIdentifier ?? FSItem.Identifier(UInt64(objectID) + 16)
    }

    private func attributes(for item: PhoneBridgeItem) -> FSItem.Attributes {
        let (entry, fileID, parent) = lock.withLock { (item.entry, item.fileIdentifier, item.parentObjectID) }
        let attributes = FSItem.Attributes()
        attributes.type = entry.isFolder ? .directory : .file
        attributes.mode = entry.isFolder ? UInt32(S_IFDIR) | (writable ? 0o755 : 0o555) : UInt32(S_IFREG) | (writable ? 0o644 : 0o444)
        attributes.linkCount = entry.isFolder ? 2 : 1
        attributes.uid = getuid()
        attributes.gid = getgid()
        attributes.flags = 0
        attributes.size = entry.size
        attributes.allocSize = entry.size
        attributes.fileID = fileID
        attributes.parentID = item.isRoot ? .parentOfRoot : identifier(forObject: parent)
        let seconds = entry.modified ?? 0
        let time = timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - seconds.rounded(.down)) * 1_000_000_000))
        attributes.modifyTime = time
        attributes.changeTime = time
        attributes.accessTime = time
        attributes.birthTime = time
        return attributes
    }

    private static func verifier(for entries: [RemoteEntry]) -> UInt64 {
        var value: UInt64 = 1469598103934665603
        for entry in entries {
            value = (value ^ UInt64(entry.objectID)) &* 1099511628211
            value = (value ^ entry.size) &* 1099511628211
        }
        return value == 0 ? 1 : value
    }

    private static let settableAttributes: [FSItem.Attribute] = [
        .type, .mode, .linkCount, .uid, .gid, .flags, .size, .allocSize, .fileID, .parentID,
        .accessTime, .modifyTime, .changeTime, .birthTime, .backupTime, .addedTime,
    ]

    private static func requested(_ request: FSItem.SetAttributesRequest) -> FSItem.Attribute {
        var result: FSItem.Attribute = []
        for attribute in settableAttributes where request.isValid(attribute) { result.insert(attribute) }
        return result
    }

    // MARK: - Local file I/O

    private static func readLocal(_ url: URL, offset: UInt64, length: Int) throws(FinderIPCError) -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            throw FinderIPCError(code: EIO, message: "buffer read: \(error.publicSummary)")
        }
    }

    /// Writes at `offset`; returns the new file size.
    private static func writeLocal(_ data: Data, to url: URL, at offset: UInt64) throws(FinderIPCError) -> UInt64 {
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            return try handle.seekToEnd()
        } catch {
            let ns = error as NSError
            let full = ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)
            throw FinderIPCError(code: full ? ENOSPC : EIO, message: "buffer write: \(error.publicSummary)")
        }
    }

    private static func truncateLocal(_ url: URL, to size: UInt64) throws(FinderIPCError) {
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: size)
        } catch {
            throw FinderIPCError(code: EIO, message: "buffer truncate: \(error.publicSummary)")
        }
    }
}
