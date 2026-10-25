import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Virtual Android device for UI development and tests. Never mixed with real
/// devices: it has its own DeviceID, `isMock == true`, and its own sidebar
/// section. It is fully writable (in memory) and can inject faults so the
/// transfer engine can be tested without hardware.
final class MockDeviceFileSystem: DeviceFileSystem {
    struct Node: Sendable {
        var objectID: UInt32
        var storageID: UInt32
        var parentID: UInt32
        var name: String
        var isFolder: Bool
        var size: UInt64?
        var modified: Date?
        /// Stored bytes for uploaded files; sample files generate a pattern.
        var content: Data? = nil
    }

    enum Operation: Hashable, Sendable {
        case list, download, upload, createFolder, rename, delete, move, copy, read
    }

    struct Faults: Sendable {
        var chunkSize = 1 << 20
        /// Pause after every chunk (makes cancellation / unplug testable).
        var chunkDelay: Duration = .zero
        /// Abort a transfer with `transferFailure` after this many bytes.
        var failAfterBytes: UInt64?
        var transferFailure: DeviceError = .usbError(code: -1, detail: "mock transfer failure")
        /// Leave a partially written object behind when an upload fails.
        var leavePartialUploads = false
        /// Keep uploaded bytes in memory (off for multi-GB tests).
        var storeUploadedContent = true
        /// Report a smaller size than received (simulates a truncated write).
        var corruptUploads = false
        /// Uploads larger than this keep no bytes (reads return the sample
        /// pattern), so a multi-gigabyte test copy does not fill memory.
        var maxStoredContentSize: UInt64 = .max
        var failing: [Operation: DeviceError] = [:]
        /// Fails only the n-th call (1-based, counted from now) of an operation.
        var failingCall: [Operation: (call: Int, error: DeviceError)] = [:]
        /// Fails the n-th call and every later one (e.g. a step and its undo).
        var failingFromCall: [Operation: (call: Int, error: DeviceError)] = [:]
        /// Deleting a folder deletes everything in it, as Android's MtpServer
        /// does. Off: deleting a non-empty folder fails.
        var deletesFoldersRecursively = false
        /// Objects that exist but are left out of listings, as libmtp does
        /// when it cannot read an object's metadata. `childCount` counts them.
        var unlistedObjects: Set<UInt32> = []
        /// Added to the device when the next download finishes (something
        /// on the phone writing while a transfer runs).
        var nodesAddedAfterDownload: [Node] = []
    }

    static let internalStorageID: UInt32 = 0x0001_0001
    static let sdCardStorageID: UInt32 = 0x0002_0001

    let deviceID: DeviceID
    let isMock = true
    let generation: UInt64 = 1
    let deviceInfo: MTPDeviceInfo
    let capabilities: FileSystemCapabilities

    private struct State {
        var nodes: [UInt32: Node]
        var storages: [StorageInfo]
        var nextID: UInt32
        var faults: Faults
        var isDisconnected = false
        var operationLog: [Operation] = []
    }

    private let state: Mutex<State>
    private let latency: Duration

    init(deviceID: DeviceID = .demo, latency: Duration = .zero, nodes: [Node]? = nil, storages: [StorageInfo]? = nil,
         capabilities: FileSystemCapabilities = .full, faults: Faults = Faults()) {
        self.deviceID = deviceID
        self.latency = latency
        self.capabilities = capabilities
        deviceInfo = MTPDeviceInfo(manufacturer: "PhoneBridge", model: "Virtual Android", serialNumber: "DEMO-0001",
                                   deviceVersion: "Mock 1.0", friendlyName: nil, batteryLevel: 82)
        let storageList = storages ?? [
            StorageInfo(id: Self.internalStorageID, name: "내부 저장공간", capacity: 256_000_000_000,
                        freeSpace: 98_400_000_000, kind: .internalStorage),
            StorageInfo(id: Self.sdCardStorageID, name: "SD 카드", capacity: 64_000_000_000,
                        freeSpace: 41_200_000_000, kind: .removable),
        ]
        let allNodes = nodes ?? Self.sampleTree()
        let maxID = allNodes.map(\.objectID).max() ?? 0x100
        state = Mutex(State(nodes: Dictionary(uniqueKeysWithValues: allNodes.map { ($0.objectID, $0) }),
                            storages: storageList, nextID: maxID + 1, faults: faults))
    }

    // MARK: - Test controls

    func configureFaults(_ mutate: (inout Faults) -> Void) {
        state.withLock { mutate(&$0.faults) }
    }

    /// Simulates pulling the cable: every call (and running transfers at their
    /// next chunk) fails with `.disconnected`.
    func simulateDisconnect() {
        state.withLock { $0.isDisconnected = true }
    }

    func setFreeSpace(_ bytes: UInt64, storageID: UInt32) {
        state.withLock { state in
            if let index = state.storages.firstIndex(where: { $0.id == storageID }) {
                state.storages[index].freeSpace = bytes
            }
        }
    }

    func node(_ objectID: UInt32) -> Node? {
        state.withLock { $0.nodes[objectID] }
    }

    func nodes(named name: String) -> [Node] {
        state.withLock { $0.nodes.values.filter { $0.name == name }.sorted { $0.objectID < $1.objectID } }
    }

    func children(of parentID: UInt32, storageID: UInt32) -> [Node] {
        state.withLock { Self.children(in: $0, parentID: parentID, storageID: storageID) }
    }

    var operationLog: [Operation] { state.withLock { $0.operationLog } }

    // MARK: - DeviceFileSystem

    func storages() async throws(DeviceError) -> [StorageInfo] {
        await simulateLatency()
        return try state.withLock { state throws(DeviceError) in
            try Self.checkConnected(state)
            return state.storages
        }
    }

    func contents(of folder: FileItemID) async throws(DeviceError) -> [FileItem] {
        await simulateLatency()
        return try state.withLock { state throws(DeviceError) in
            try Self.begin(.list, in: &state)
            try validateFolder(folder, in: state)
            return Self.children(in: state, parentID: folder.objectID, storageID: folder.storageID)
                .filter { !state.faults.unlistedObjects.contains($0.objectID) }
                .map(fileItem)
        }
    }

    func childCount(of folder: FileItemID) async throws(DeviceError) -> Int {
        await simulateLatency()
        return try state.withLock { state throws(DeviceError) in
            try Self.begin(.list, in: &state)
            try validateFolder(folder, in: state)
            return Self.children(in: state, parentID: folder.objectID, storageID: folder.storageID).count
        }
    }

    func item(_ id: FileItemID) async throws(DeviceError) -> FileItem {
        try state.withLock { state throws(DeviceError) in
            try Self.checkConnected(state)
            guard id.deviceID == deviceID, let node = state.nodes[id.objectID] else { throw .objectNotFound }
            return fileItem(node)
        }
    }

    func download(_ id: FileItemID, to fileURL: URL, progress: TransferProgress) async throws(DeviceError) {
        await simulateLatency()
        let (node, faults) = try state.withLock { state throws(DeviceError) in
            try Self.begin(.download, in: &state)
            guard id.deviceID == deviceID, let node = state.nodes[id.objectID], !node.isFolder else { throw .objectNotFound }
            return (node, state.faults)
        }
        let fd = try LocalFileIO.openForWriting(fileURL)
        defer { close(fd) }
        let total = node.content.map { UInt64($0.count) } ?? node.size ?? 0
        var written: UInt64 = 0
        progress.update(completed: 0, total: total)
        while written < total {
            try checkTransferInterruptions(progress: progress, transferred: written, faults: faults)
            let count = Int(min(UInt64(faults.chunkSize), total - written))
            let chunk = node.content.map { $0.subdata(in: Int(written)..<Int(written) + count) }
                ?? Self.pattern(objectID: node.objectID, offset: written, count: count)
            try LocalFileIO.writeAll(fd, chunk, url: fileURL)
            written += UInt64(count)
            progress.update(completed: written, total: total)
            if faults.chunkDelay > .zero { try? await Task.sleep(for: faults.chunkDelay) }
        }
        guard fsync(fd) == 0 else { throw LocalFileIO.mapErrno(errno, url: fileURL, writing: true) }
        state.withLock { state in
            for added in state.faults.nodesAddedAfterDownload { state.nodes[added.objectID] = added }
            state.faults.nodesAddedAfterDownload = []
        }
    }

    func upload(from fileURL: URL, size: UInt64, named rawName: String, into folder: FileItemID, modified: Date?,
                progress: TransferProgress) async throws(DeviceError) -> FileItem {
        // Stored as the real device path stores it (NFC).
        let name = FileNameRules.deviceForm(rawName)
        await simulateLatency()
        let faults = try state.withLock { state throws(DeviceError) in
            try Self.begin(.upload, in: &state)
            try requireWritable(folder.storageID, in: state)
            try validateFolder(folder, in: state)
            try Self.checkNameFree(name, parentID: folder.objectID, storageID: folder.storageID, excluding: nil, in: state)
            let free = state.storages.first { $0.id == folder.storageID }?.freeSpace ?? .max
            guard size <= free else { throw .storageFull }
            return state.faults
        }

        let fd = try LocalFileIO.openForReading(fileURL)
        defer { close(fd) }
        var received: UInt64 = 0
        var content = faults.storeUploadedContent && size <= faults.maxStoredContentSize ? Data() : nil
        var buffer = [UInt8](repeating: 0, count: faults.chunkSize)
        progress.update(completed: 0, total: size)
        do throws(DeviceError) {
            while received < size {
                try checkTransferInterruptions(progress: progress, transferred: received, faults: faults)
                let wanted = Int(min(UInt64(faults.chunkSize), size - received))
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
                guard count > 0 else {
                    if count < 0 { throw LocalFileIO.mapErrno(errno, url: fileURL, writing: false) }
                    break // source shrank; verification will catch the mismatch
                }
                content?.append(contentsOf: buffer[0..<count])
                received += UInt64(count)
                progress.update(completed: received, total: size)
                if faults.chunkDelay > .zero { try? await Task.sleep(for: faults.chunkDelay) }
            }
        } catch {
            if faults.leavePartialUploads {
                _ = insertNode(name: name, folder: folder, isFolder: false, size: received, modified: modified, content: nil)
            }
            throw error
        }

        let reportedSize = faults.corruptUploads ? received / 2 : received
        let node = insertNode(name: name, folder: folder, isFolder: false, size: reportedSize, modified: modified ?? Date(),
                              content: content)
        return fileItem(node)
    }

    func createFolder(named rawName: String, in folder: FileItemID) async throws(DeviceError) -> FileItem {
        let name = FileNameRules.deviceForm(rawName)
        await simulateLatency()
        try state.withLock { state throws(DeviceError) in
            try Self.begin(.createFolder, in: &state)
            try requireWritable(folder.storageID, in: state)
            try validateFolder(folder, in: state)
            try Self.checkNameFree(name, parentID: folder.objectID, storageID: folder.storageID, excluding: nil, in: state)
        }
        return fileItem(insertNode(name: name, folder: folder, isFolder: true, size: nil, modified: Date(), content: nil))
    }

    func rename(_ id: FileItemID, to rawName: String) async throws(DeviceError) -> FileItem {
        let name = FileNameRules.deviceForm(rawName)
        await simulateLatency()
        guard capabilities.canRename else { throw .unsupportedOperation }
        return try state.withLock { state throws(DeviceError) in
            try Self.begin(.rename, in: &state)
            guard var node = state.nodes[id.objectID] else { throw .objectNotFound }
            try requireWritable(node.storageID, in: state)
            try Self.checkNameFree(name, parentID: node.parentID, storageID: node.storageID, excluding: node.objectID, in: state)
            node.name = name
            state.nodes[node.objectID] = node
            return fileItem(node)
        }
    }

    func delete(_ id: FileItemID) async throws(DeviceError) {
        await simulateLatency()
        try state.withLock { state throws(DeviceError) in
            try Self.begin(.delete, in: &state)
            guard let node = state.nodes[id.objectID] else { throw .objectNotFound }
            try requireWritable(node.storageID, in: state)
            let children = Self.children(in: state, parentID: node.objectID, storageID: node.storageID)
            if state.faults.deletesFoldersRecursively {
                for descendant in Self.descendants(of: node, in: state) {
                    state.nodes[descendant.objectID] = nil
                    Self.adjustFreeSpace(storageID: descendant.storageID, by: Int64(descendant.size ?? 0), in: &state)
                }
            } else if !children.isEmpty {
                // Stricter than Android by default: callers must empty folders first.
                throw .protocolError(code: 0x200C, detail: "mock: folder not empty")
            }
            state.nodes[node.objectID] = nil
            Self.adjustFreeSpace(storageID: node.storageID, by: Int64(node.size ?? 0), in: &state)
        }
    }

    func move(_ id: FileItemID, to folder: FileItemID) async throws(DeviceError) -> FileItem {
        await simulateLatency()
        guard capabilities.canMoveNatively else { throw .unsupportedOperation }
        return try state.withLock { state throws(DeviceError) in
            try Self.begin(.move, in: &state)
            guard var node = state.nodes[id.objectID] else { throw .objectNotFound }
            try requireWritable(folder.storageID, in: state)
            try validateFolder(folder, in: state)
            if Self.isDescendant(folder.objectID, of: node.objectID, in: state) { throw .invalidDestination }
            try Self.checkNameFree(node.name, parentID: folder.objectID, storageID: folder.storageID, excluding: node.objectID, in: state)
            node.parentID = folder.objectID
            let oldStorage = node.storageID
            node.storageID = folder.storageID
            state.nodes[node.objectID] = node
            if oldStorage != folder.storageID {
                Self.reassignStorage(below: node.objectID, from: oldStorage, to: folder.storageID, in: &state)
            }
            return fileItem(node)
        }
    }

    func copy(_ id: FileItemID, to folder: FileItemID) async throws(DeviceError) -> FileItem {
        await simulateLatency()
        guard capabilities.canCopyNatively else { throw .unsupportedOperation }
        return try state.withLock { state throws(DeviceError) in
            try Self.begin(.copy, in: &state)
            guard let source = state.nodes[id.objectID] else { throw .objectNotFound }
            try requireWritable(folder.storageID, in: state)
            try validateFolder(folder, in: state)
            if Self.isDescendant(folder.objectID, of: source.objectID, in: state) { throw .invalidDestination }
            try Self.checkNameFree(source.name, parentID: folder.objectID, storageID: folder.storageID, excluding: nil, in: state)
            let copy = Self.deepCopy(source, parentID: folder.objectID, storageID: folder.storageID, in: &state)
            return fileItem(copy)
        }
    }

    func thumbnail(_ id: FileItemID) async throws(DeviceError) -> Data {
        let node = try state.withLock { state throws(DeviceError) in
            try Self.checkConnected(state)
            guard let node = state.nodes[id.objectID], FileCategory(fileName: node.name) == .image else { throw .objectNotFound }
            return node
        }
        return try Self.placeholderThumbnail(seed: node.objectID)
    }

    func read(_ id: FileItemID, offset: UInt64, length: Int) async throws(DeviceError) -> Data {
        await simulateLatency()
        guard capabilities.canReadPartially else { throw .unsupportedOperation }
        let node = try state.withLock { state throws(DeviceError) in
            try Self.begin(.read, in: &state)
            guard id.deviceID == deviceID, let node = state.nodes[id.objectID], !node.isFolder else { throw .objectNotFound }
            return node
        }
        let total = node.content.map { UInt64($0.count) } ?? node.size ?? 0
        guard offset < total, length > 0 else { return Data() }
        let count = Int(min(UInt64(length), total - offset))
        if let content = node.content {
            return content.subdata(in: Int(offset)..<Int(offset) + count)
        }
        // Pattern bytes change every MiB; build the range piecewise.
        var result = Data(capacity: count)
        var position = offset
        while result.count < count {
            let chunkEnd = min((position / (1 << 20) + 1) * (1 << 20), offset + UInt64(count))
            result.append(Self.pattern(objectID: node.objectID, offset: position, count: Int(chunkEnd - position)))
            position = chunkEnd
        }
        return result
    }

    // MARK: - Internals

    private func simulateLatency() async {
        if latency > .zero {
            try? await Task.sleep(for: latency)
        }
    }

    private func fileItem(_ node: Node) -> FileItem {
        FileItem(id: FileItemID(deviceID: deviceID, storageID: node.storageID, objectID: node.objectID),
                 name: node.name, isFolder: node.isFolder, size: node.isFolder ? nil : node.size, modified: node.modified)
    }

    private func validateFolder(_ folder: FileItemID, in state: State) throws(DeviceError) {
        guard folder.deviceID == deviceID, state.storages.contains(where: { $0.id == folder.storageID }) else {
            throw .objectNotFound
        }
        if !folder.isStorageRoot {
            guard let node = state.nodes[folder.objectID], node.isFolder, node.storageID == folder.storageID else {
                throw .objectNotFound
            }
        }
    }

    private func requireWritable(_ storageID: UInt32, in state: State) throws(DeviceError) {
        guard capabilities.canWrite else { throw .unsupportedOperation }
        if state.storages.first(where: { $0.id == storageID })?.isReadOnly == true { throw .readOnlyStorage }
    }

    private func checkTransferInterruptions(progress: TransferProgress, transferred: UInt64, faults: Faults) throws(DeviceError) {
        if progress.isCancelled { throw .cancelled }
        if state.withLock({ $0.isDisconnected }) { throw .disconnected }
        if let limit = faults.failAfterBytes, transferred >= limit { throw faults.transferFailure }
    }

    private func insertNode(name: String, folder: FileItemID, isFolder: Bool, size: UInt64?, modified: Date?,
                            content: Data?) -> Node {
        state.withLock { state in
            let node = Node(objectID: state.nextID, storageID: folder.storageID, parentID: folder.objectID, name: name,
                            isFolder: isFolder, size: size, modified: modified, content: content)
            state.nextID += 1
            state.nodes[node.objectID] = node
            Self.adjustFreeSpace(storageID: folder.storageID, by: -Int64(size ?? 0), in: &state)
            return node
        }
    }

    private static func begin(_ operation: Operation, in state: inout State) throws(DeviceError) {
        try checkConnected(state)
        state.operationLog.append(operation)
        if let error = state.faults.failing[operation] { throw error }
        if let planned = state.faults.failingCall[operation] {
            if planned.call <= 1 {
                state.faults.failingCall[operation] = nil
                throw planned.error
            }
            state.faults.failingCall[operation] = (planned.call - 1, planned.error)
        }
        if let planned = state.faults.failingFromCall[operation] {
            if planned.call <= 1 { throw planned.error }
            state.faults.failingFromCall[operation] = (planned.call - 1, planned.error)
        }
    }

    private static func checkConnected(_ state: State) throws(DeviceError) {
        if state.isDisconnected { throw .disconnected }
    }

    private static func children(in state: State, parentID: UInt32, storageID: UInt32) -> [Node] {
        state.nodes.values
            .filter { $0.parentID == parentID && $0.storageID == storageID }
            .sorted { $0.objectID < $1.objectID }
    }

    /// Android's shared storage is case-insensitive, so the mock is too.
    private static func checkNameFree(_ name: String, parentID: UInt32, storageID: UInt32, excluding: UInt32?,
                                      in state: State) throws(DeviceError) {
        let clash = children(in: state, parentID: parentID, storageID: storageID).contains {
            $0.objectID != excluding && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        if clash { throw .nameConflict(name: name) }
    }

    private static func descendants(of node: Node, in state: State) -> [Node] {
        var result: [Node] = []
        var pending = [node]
        while let folder = pending.popLast() {
            let children = Self.children(in: state, parentID: folder.objectID, storageID: folder.storageID)
            result += children
            pending += children.filter(\.isFolder)
        }
        return result
    }

    private static func isDescendant(_ candidate: UInt32, of ancestor: UInt32, in state: State) -> Bool {
        var current = candidate
        while current != FileItemID.rootObjectID {
            if current == ancestor { return true }
            guard let parent = state.nodes[current]?.parentID else { return false }
            current = parent
        }
        return false
    }

    private static func reassignStorage(below parentID: UInt32, from oldStorage: UInt32, to newStorage: UInt32,
                                        in state: inout State) {
        for child in children(in: state, parentID: parentID, storageID: oldStorage) {
            state.nodes[child.objectID]?.storageID = newStorage
            reassignStorage(below: child.objectID, from: oldStorage, to: newStorage, in: &state)
        }
    }

    private static func deepCopy(_ source: Node, parentID: UInt32, storageID: UInt32, in state: inout State) -> Node {
        var copy = source
        copy.objectID = state.nextID
        state.nextID += 1
        copy.parentID = parentID
        copy.storageID = storageID
        state.nodes[copy.objectID] = copy
        adjustFreeSpace(storageID: storageID, by: -Int64(source.size ?? 0), in: &state)
        for child in children(in: state, parentID: source.objectID, storageID: source.storageID) {
            _ = deepCopy(child, parentID: copy.objectID, storageID: storageID, in: &state)
        }
        return copy
    }

    private static func adjustFreeSpace(storageID: UInt32, by delta: Int64, in state: inout State) {
        guard let index = state.storages.firstIndex(where: { $0.id == storageID }),
              let free = state.storages[index].freeSpace else { return }
        state.storages[index].freeSpace = delta >= 0 ? free &+ UInt64(delta) : free - min(free, UInt64(-delta))
    }

    /// Deterministic bytes for sample files that have no stored content.
    static func pattern(objectID: UInt32, offset: UInt64, count: Int) -> Data {
        Data(repeating: UInt8(truncatingIfNeeded: objectID &+ UInt32(truncatingIfNeeded: offset >> 20)), count: count)
    }

    /// Extra demo-only content for checking Finder/Quick Look: a 5 GB virtual
    /// video (pattern bytes, > 4 GiB offsets) and real PNG / PDF / text files.
    /// Not part of `sampleTree()`, so test fixtures stay unchanged.
    static func demoExtras() -> [Node] {
        let root = FileItemID.rootObjectID
        let storage = internalStorageID
        let folderID: UInt32 = 0x8000
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        var nodes = [Node(objectID: folderID, storageID: storage, parentID: root, name: "PhoneBridge 테스트",
                          isFolder: true, size: nil, modified: date)]
        nodes.append(Node(objectID: 0x8001, storageID: storage, parentID: folderID, name: "대용량_5GB_영상.mov",
                          isFolder: false, size: 5_000_000_000, modified: date))
        let samples: [(UInt32, String, Data?)] = [
            (0x8002, "미리보기_이미지.png", samplePNG()),
            (0x8003, "미리보기_문서.pdf", samplePDF()),
            (0x8004, "미리보기_메모.txt", Data("PhoneBridge Finder 미리보기 테스트\nHello from the virtual Android device 😀\n".utf8)),
        ]
        for (id, name, data) in samples {
            guard let data else { continue }
            nodes.append(Node(objectID: id, storageID: storage, parentID: folderID, name: name, isFolder: false,
                              size: UInt64(data.count), modified: date, content: data))
        }
        return nodes
    }

    private static func samplePNG() -> Data? {
        let width = 1200, height = 800
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for band in 0..<8 {
            let hue = CGFloat(band) / 8
            context.setFillColor(CGColor(red: 0.2 + hue * 0.6, green: 0.5, blue: 0.9 - hue * 0.6, alpha: 1))
            context.fill(CGRect(x: band * width / 8, y: 0, width: width / 8, height: height))
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: 450, y: 250, width: 300, height: 300))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func samplePDF() -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for page in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.15, green: 0.35 + CGFloat(page) * 0.3, blue: 0.75, alpha: 1))
            context.fill(CGRect(x: 60, y: 600, width: 475, height: 160))
            context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
            for line in 0..<12 {
                context.fill(CGRect(x: 60, y: 540 - line * 36, width: 475 - (line % 3) * 90, height: 14))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func placeholderThumbnail(seed: UInt32) throws(DeviceError) -> Data {
        let size = 96
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw .outOfMemory }
        let hue = CGFloat(seed % 12) / 12
        context.setFillColor(CGColor(red: 0.3 + hue * 0.5, green: 0.55, blue: 0.9 - hue * 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.6))
        context.fillEllipse(in: CGRect(x: 28, y: 40, width: 40, height: 40))
        guard let image = context.makeImage() else { throw .outOfMemory }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw .outOfMemory
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw .outOfMemory }
        return data as Data
    }

    // MARK: - Sample data

    /// Deterministic tree resembling an Android phone's shared storage.
    static func sampleTree() -> [Node] {
        var builder = TreeBuilder()
        let root = FileItemID.rootObjectID
        let s1 = internalStorageID
        let s2 = sdCardStorageID

        let dcim = builder.folder("DCIM", in: root, storage: s1, day: 0)
        let camera = builder.folder("Camera", in: dcim, storage: s1, day: 1)
        for index in 1...12 {
            builder.file(String(format: "IMG_20260%d%02d_1030%02d.jpg", 9, index, index), in: camera, storage: s1,
                         size: UInt64(2_400_000 + index * 137_000), day: 10 + index)
        }
        builder.file("VID_20260915_183012.mp4", in: camera, storage: s1, size: 184_220_310, day: 14)
        let screenshots = builder.folder("Screenshots", in: dcim, storage: s1, day: 2)
        builder.file("Screenshot_20261001_091522.png", in: screenshots, storage: s1, size: 812_004, day: 30)
        builder.file("Screenshot_20261012_224810.png", in: screenshots, storage: s1, size: 655_120, day: 41)

        let download = builder.folder("Download", in: root, storage: s1, day: 3)
        builder.file("회의록_2026년_10월.pdf", in: download, storage: s1, size: 1_204_331, day: 42)
        builder.file("견적서2.xlsx", in: download, storage: s1, size: 48_220, day: 39)
        builder.file("견적서10.xlsx", in: download, storage: s1, size: 51_908, day: 40)
        builder.file("PhoneBridge-guide.hwp", in: download, storage: s1, size: 233_812, day: 38)
        builder.file("app-release.apk", in: download, storage: s1, size: 38_400_120, day: 20)
        builder.file("archive.zip", in: download, storage: s1, size: 12_002_311, day: 18)

        let documents = builder.folder("Documents", in: root, storage: s1, day: 4)
        builder.file("메모.txt", in: documents, storage: s1, size: 2_048, day: 35)
        builder.file("가계부 2026.xlsx", in: documents, storage: s1, size: 88_123, day: 33)
        _ = builder.folder("빈 폴더", in: documents, storage: s1, day: 5)

        let music = builder.folder("Music", in: root, storage: s1, day: 5)
        builder.file("봄날.mp3", in: music, storage: s1, size: 8_812_004, day: 7)
        builder.file("Recording 001.m4a", in: music, storage: s1, size: 3_120_400, day: 9)

        let pictures = builder.folder("Pictures", in: root, storage: s1, day: 6)
        let kakao = builder.folder("KakaoTalk", in: pictures, storage: s1, day: 8)
        builder.file("가족사진.jpg", in: kakao, storage: s1, size: 1_820_441, day: 28)
        builder.file("여행_제주.heic", in: kakao, storage: s1, size: 2_920_113, day: 29)

        _ = builder.folder("Movies", in: root, storage: s1, day: 6)
        let android = builder.folder("Android", in: root, storage: s1, day: 0)
        _ = builder.folder("data", in: android, storage: s1, day: 0)
        _ = builder.folder("media", in: android, storage: s1, day: 0)

        let sdDCIM = builder.folder("DCIM", in: root, storage: s2, day: 1)
        builder.file("IMG_20250101_000001.jpg", in: sdDCIM, storage: s2, size: 3_100_000, day: 0)
        let backup = builder.folder("Backup", in: root, storage: s2, day: 2)
        builder.file("contacts.vcf", in: backup, storage: s2, size: 18_442, day: 3)

        return builder.nodes
    }

    private struct TreeBuilder {
        var nodes: [Node] = []
        private var nextID: UInt32 = 0x100
        // 2026-09-01 00:00:00 UTC; fixed so tests and screenshots are stable.
        private let baseDate = Date(timeIntervalSince1970: 1_788_220_800)

        mutating func folder(_ name: String, in parent: UInt32, storage: UInt32, day: Int) -> UInt32 {
            add(name, parent: parent, storage: storage, isFolder: true, size: nil, day: day)
        }

        mutating func file(_ name: String, in parent: UInt32, storage: UInt32, size: UInt64, day: Int) {
            _ = add(name, parent: parent, storage: storage, isFolder: false, size: size, day: day)
        }

        private mutating func add(_ name: String, parent: UInt32, storage: UInt32, isFolder: Bool,
                                  size: UInt64?, day: Int) -> UInt32 {
            let id = nextID
            nextID += 1
            let modified = baseDate.addingTimeInterval(TimeInterval(day * 86_400 + Int(id % 977) * 37))
            nodes.append(Node(objectID: id, storageID: storage, parentID: parent, name: name,
                              isFolder: isFolder, size: size, modified: modified))
            return id
        }
    }
}
