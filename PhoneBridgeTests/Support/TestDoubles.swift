import Foundation
import Testing
@testable import PhoneBridge

// MARK: - USB monitor

final class MockUSBMonitor: USBDeviceMonitoring, @unchecked Sendable {
    let events: AsyncStream<USBEvent>
    private let continuation: AsyncStream<USBEvent>.Continuation
    private let lock = NSLock()
    private var owners: [UInt64: String] = [:]

    init() {
        (events, continuation) = AsyncStream.makeStream(of: USBEvent.self)
    }

    func start() {}
    func stop() {}

    func send(_ event: USBEvent) {
        continuation.yield(event)
    }

    func setOwner(_ owner: String?, registryID: UInt64) {
        lock.withLock { owners[registryID] = owner }
    }

    func exclusiveOwner(registryID: UInt64) async -> String? {
        lock.withLock { owners[registryID] }
    }
}

// MARK: - MTP backend

/// Scriptable fake of libmtp with an in-memory object store. Records how it
/// is called so tests can assert serialization (never two calls at once) and
/// that no call runs on the main thread. Transfers go through real file
/// descriptors, like the libmtp bridge.
final class MockMTPBackend: MTPBackend, @unchecked Sendable {
    struct Script {
        var preflight: MTPPreflightResult = .available
        /// Preflight calls that report "no device" before `preflight` applies.
        var transientPreflightFailures = 0
        /// Number of `open` calls that fail before one succeeds.
        var openFailures = 0
        var openError: DeviceError = .sessionOpenFailed(detail: "mock open failure")
        var info = MTPDeviceInfo(manufacturer: "Google", model: "Pixel 8", serialNumber: "SERIAL1",
                                 deviceVersion: "1.0", friendlyName: nil, batteryLevel: 77)
        var capabilities: MTPCapabilities = [.rename, .moveObject]
        var storages = [StorageInfo(id: 0x0001_0001, name: "내부 저장공간", capacity: 128_000_000_000,
                                    freeSpace: 64_000_000_000, kind: .internalStorage)]
        /// Number of `storages()` calls that report zero storages (locked).
        var lockedPolls = 0
        /// Simulated blocking time per call.
        var callDelay: TimeInterval = 0
        /// Simulated blocking time per 64 KiB transfer chunk.
        var chunkDelay: TimeInterval = 0
        /// The n-th SendPartialObject (1-based) fails like a pulled cable.
        var failPartialSend: Int?
        /// The n-th GetPartialObject (1-based) fails with a protocol error
        /// (e.g. a 32-bit offset limit).
        var failPartialRead: Int?
    }

    private let lock = NSLock()
    private var script = Script()
    private var openFailuresLeft = 0
    private var lockedPollsLeft = 0
    private var activeCalls = 0
    private var objects: [UInt32: MTPObjectInfo] = [:]
    private var contents: [UInt32: Data] = [:]
    private var nextID: UInt32 = 0x1000
    private var unplugged = false

    private(set) var openCount = 0
    private(set) var closeCount = 0
    private(set) var maxConcurrentCalls = 0
    private(set) var mainThreadCalls = 0
    private(set) var totalCalls = 0
    private(set) var partialReads = 0
    /// Order of listing and edit-extension calls (chunked uploads).
    private(set) var trace: [String] = []
    private var editing: Set<UInt32> = []
    private var partialSends = 0
    private(set) var fullDownloads = 0

    init() {
        for object in Self.sampleTree().values.joined() {
            objects[object.objectID] = object
        }
    }

    /// Puts an object on the mock device as-is (e.g. a name no Android would allow).
    func addObject(_ object: MTPObjectInfo, content: Data? = nil) {
        lock.withLock {
            objects[object.objectID] = object
            contents[object.objectID] = content
        }
    }

    func configure(_ mutate: (inout Script) -> Void) {
        lock.withLock {
            mutate(&script)
            openFailuresLeft = script.openFailures
            lockedPollsLeft = script.lockedPolls
        }
    }

    /// Makes running and future calls fail like a pulled cable.
    func unplug() {
        lock.withLock { unplugged = true }
    }

    func replug() {
        lock.withLock { unplugged = false }
    }

    var transferCounts: (partialReads: Int, fullDownloads: Int) {
        lock.withLock { (partialReads, fullDownloads) }
    }

    var stats: (open: Int, close: Int, maxConcurrent: Int, mainThread: Int, total: Int) {
        lock.withLock { (openCount, closeCount, maxConcurrentCalls, mainThreadCalls, totalCalls) }
    }

    func object(named name: String) -> MTPObjectInfo? {
        lock.withLock { objects.values.first { $0.name == name } }
    }

    func content(of objectID: UInt32) -> Data? {
        lock.withLock { contents[objectID] }
    }

    func children(of parentID: UInt32) -> [MTPObjectInfo] {
        lock.withLock { objects.values.filter { $0.parentID == parentID }.sorted { $0.objectID < $1.objectID } }
    }

    func preflight(_ target: MTPTarget) -> MTPPreflightResult {
        instrumented {
            if script.transientPreflightFailures > 0 {
                script.transientPreflightFailures -= 1
                return .failed(.disconnected)
            }
            return script.preflight
        }
    }

    func open(_ target: MTPTarget) throws(DeviceError) -> any MTPConnection {
        let result: Result<Void, DeviceError> = instrumented {
            openCount += 1
            if openFailuresLeft > 0 {
                openFailuresLeft -= 1
                return .failure(script.openError)
            }
            return .success(())
        }
        try result.get()
        return MockMTPConnection(backend: self)
    }

    fileprivate func deviceInfo() -> MTPDeviceInfo { instrumented { script.info } }
    fileprivate func capabilities() -> MTPCapabilities { instrumented { script.capabilities } }

    fileprivate func storages() -> [StorageInfo] {
        instrumented {
            if lockedPollsLeft > 0 {
                lockedPollsLeft -= 1
                return []
            }
            return script.storages
        }
    }

    fileprivate func listFolder(storageID: UInt32, parentID: UInt32) throws(DeviceError) -> [MTPObjectInfo] {
        let result: Result<[MTPObjectInfo], DeviceError> = instrumented {
            trace.append("list")
            if unplugged { return .failure(.disconnected) }
            if parentID != FileItemID.rootObjectID, objects[parentID]?.isFolder != true {
                return .failure(.objectNotFound)
            }
            return .success(objects.values.filter { $0.parentID == parentID && $0.storageID == storageID }
                .sorted { $0.objectID < $1.objectID })
        }
        return try result.get()
    }

    fileprivate func childCount(storageID: UInt32, parentID: UInt32) throws(DeviceError) -> Int {
        try listFolder(storageID: storageID, parentID: parentID).count
    }

    fileprivate func objectInfo(objectID: UInt32) throws(DeviceError) -> MTPObjectInfo {
        let result: Result<MTPObjectInfo, DeviceError> = instrumented {
            objects[objectID].map { .success($0) } ?? .failure(.objectNotFound)
        }
        return try result.get()
    }

    fileprivate func download(objectID: UInt32, to fd: Int32, progress: TransferProgress) throws(DeviceError) {
        let source: Result<Data, DeviceError> = instrumented {
            fullDownloads += 1
            guard let object = objects[objectID], !object.isFolder else { return .failure(.objectNotFound) }
            return .success(contents[objectID] ?? Data(repeating: UInt8(truncatingIfNeeded: objectID), count: Int(object.size)))
        }
        let data = try source.get()
        try stream(count: data.count, progress: progress) { offset, count throws(DeviceError) in
            let chunk = data.subdata(in: offset..<offset + count)
            try LocalFileIO.writeAll(fd, chunk, url: URL(filePath: "/mock-fd"))
        }
    }

    fileprivate func upload(from fd: Int32, name: String, size: UInt64, storageID: UInt32, parentID: UInt32,
                            progress: TransferProgress) throws(DeviceError) -> UInt32 {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        try stream(count: Int(size), progress: progress) { _, count throws(DeviceError) in
            let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, count) }
            guard read == count else { throw DeviceError.usbError(code: -1, detail: "short read") }
            data.append(contentsOf: buffer[0..<count])
        }
        return lock.withLock {
            let id = nextID
            nextID += 1
            objects[id] = MTPObjectInfo(objectID: id, parentID: parentID == FileItemID.rootObjectID ? FileItemID.rootObjectID : parentID,
                                        storageID: storageID, name: name, size: UInt64(data.count), modified: Date(), isFolder: false)
            contents[id] = data
            return id
        }
    }

    fileprivate func createFolder(name: String, storageID: UInt32, parentID: UInt32) -> UInt32 {
        lock.withLock {
            let id = nextID
            nextID += 1
            objects[id] = MTPObjectInfo(objectID: id, parentID: parentID, storageID: storageID, name: name, size: 0,
                                        modified: Date(), isFolder: true)
            return id
        }
    }

    fileprivate func mutate(_ objectID: UInt32, _ body: (inout MTPObjectInfo) -> Void) throws(DeviceError) {
        let found: Bool = lock.withLock {
            guard var object = objects[objectID] else { return false }
            body(&object)
            objects[objectID] = object
            return true
        }
        if !found { throw .objectNotFound }
    }

    fileprivate func delete(objectID: UInt32) throws(DeviceError) {
        let removed: Bool = lock.withLock {
            contents[objectID] = nil
            return objects.removeValue(forKey: objectID) != nil
        }
        if !removed { throw .objectNotFound }
    }

    fileprivate func readPartial(objectID: UInt32, offset: UInt64, length: UInt32) throws(DeviceError) -> Data {
        let result: Result<Data, DeviceError> = instrumented {
            trace.append("read")
            partialReads += 1
            if unplugged { return .failure(.usbError(code: -4, detail: "mock unplugged")) }
            if script.failPartialRead == partialReads { return .failure(.protocolError(code: 0x2002, detail: "mock offset limit")) }
            guard script.capabilities.contains(.partialGet) else { return .failure(.unsupportedOperation) }
            guard let object = objects[objectID], !object.isFolder else { return .failure(.objectNotFound) }
            let data = contents[objectID] ?? Data(repeating: UInt8(truncatingIfNeeded: objectID), count: Int(object.size))
            guard offset < UInt64(data.count) else { return .success(Data()) }
            let end = min(data.count, Int(offset) + Int(length))
            return .success(data.subdata(in: Int(offset)..<end))
        }
        return try result.get()
    }

    var callTrace: [String] { lock.withLock { trace } }

    fileprivate func beginEdit(objectID: UInt32) throws(DeviceError) {
        let result: Result<Void, DeviceError> = instrumented {
            trace.append("begin")
            guard script.capabilities.contains(.editObjects) else { return .failure(.unsupportedOperation) }
            guard objects[objectID] != nil, !editing.contains(objectID) else { return .failure(.protocolError(code: 0x2002, detail: nil)) }
            editing.insert(objectID)
            return .success(())
        }
        try result.get()
    }

    /// Android rules: only objects open for edit, offset at most the current size.
    fileprivate func sendPartial(objectID: UInt32, offset: UInt64, data: Data) throws(DeviceError) {
        let result: Result<Void, DeviceError> = instrumented {
            trace.append("partial")
            partialSends += 1
            if unplugged || script.failPartialSend == partialSends { return .failure(.disconnected) }
            guard editing.contains(objectID), var object = objects[objectID] else { return .failure(.protocolError(code: 0x2002, detail: nil)) }
            var content = contents[objectID] ?? Data()
            guard offset <= UInt64(content.count) else { return .failure(.protocolError(code: 0x2002, detail: "past end")) }
            let end = Int(offset) + data.count
            if end > content.count { content.append(Data(count: end - content.count)) }
            content.replaceSubrange(Int(offset)..<end, with: data)
            contents[objectID] = content
            object.size = UInt64(content.count)
            objects[objectID] = object
            return .success(())
        }
        try result.get()
    }

    fileprivate func endEdit(objectID: UInt32) throws(DeviceError) {
        let result: Result<Void, DeviceError> = instrumented {
            trace.append("end")
            return editing.remove(objectID) == nil ? .failure(.protocolError(code: 0x2002, detail: nil)) : .success(())
        }
        try result.get()
    }

    fileprivate func recordClose() {
        lock.withLock { closeCount += 1 }
    }

    /// Chunked transfer loop: progress, cancellation and unplug checks.
    private func stream(count: Int, progress: TransferProgress,
                        _ body: (Int, Int) throws(DeviceError) -> Void) throws(DeviceError) {
        enter()
        defer { exit() }
        var offset = 0
        progress.update(completed: 0, total: UInt64(count))
        while offset < count {
            if progress.isCancelled { throw .cancelled }
            if lock.withLock({ unplugged }) { throw .usbError(code: -4, detail: "mock unplugged") }
            let chunk = min(64 * 1024, count - offset)
            try body(offset, chunk)
            offset += chunk
            progress.update(completed: UInt64(offset), total: UInt64(count))
            let delay = lock.withLock { script.chunkDelay }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
    }

    private func enter() {
        lock.withLock {
            activeCalls += 1
            totalCalls += 1
            maxConcurrentCalls = max(maxConcurrentCalls, activeCalls)
            if Thread.isMainThread { mainThreadCalls += 1 }
        }
    }

    private func exit() {
        lock.withLock { activeCalls -= 1 }
    }

    /// Wraps a fake blocking call: tracks concurrency and the calling thread,
    /// then sleeps (blocking, like libmtp) outside the lock.
    private func instrumented<T>(_ body: () -> T) -> T {
        let (value, delay): (T, TimeInterval) = lock.withLock {
            activeCalls += 1
            totalCalls += 1
            maxConcurrentCalls = max(maxConcurrentCalls, activeCalls)
            if Thread.isMainThread { mainThreadCalls += 1 }
            return (body(), script.callDelay)
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.withLock { activeCalls -= 1 }
        return value
    }

    static let dcimID: UInt32 = 0x10
    static let cameraID: UInt32 = 0x11
    static let downloadID: UInt32 = 0x20

    static func sampleTree(storageID: UInt32 = 0x0001_0001) -> [UInt32: [MTPObjectInfo]] {
        func folder(_ id: UInt32, _ parent: UInt32, _ name: String) -> MTPObjectInfo {
            MTPObjectInfo(objectID: id, parentID: parent, storageID: storageID, name: name, size: 0, modified: nil, isFolder: true)
        }
        func file(_ id: UInt32, _ parent: UInt32, _ name: String, _ size: UInt64) -> MTPObjectInfo {
            MTPObjectInfo(objectID: id, parentID: parent, storageID: storageID, name: name, size: size,
                          modified: Date(timeIntervalSince1970: 1_790_000_000 + TimeInterval(id)), isFolder: false)
        }
        let root = FileItemID.rootObjectID
        return [
            root: [folder(dcimID, root, "DCIM"), folder(downloadID, root, "Download"), file(0x30, root, "notes.txt", 120)],
            dcimID: [folder(cameraID, dcimID, "Camera")],
            cameraID: [file(0x12, cameraID, "IMG_0002.jpg", 2_000), file(0x13, cameraID, "IMG_0010.jpg", 3_000)],
            downloadID: [],
        ]
    }
}

private final class MockMTPConnection: MTPConnection {
    private let backend: MockMTPBackend
    private var isClosed = false

    init(backend: MockMTPBackend) {
        self.backend = backend
    }

    func deviceInfo() -> MTPDeviceInfo { backend.deviceInfo() }
    func capabilities() -> MTPCapabilities { backend.capabilities() }

    func storages() throws(DeviceError) -> [StorageInfo] {
        try requireOpen()
        return backend.storages()
    }

    func listFolder(storageID: UInt32, parentID: UInt32) throws(DeviceError) -> [MTPObjectInfo] {
        try requireOpen()
        return try backend.listFolder(storageID: storageID, parentID: parentID)
    }

    func childCount(storageID: UInt32, parentID: UInt32) throws(DeviceError) -> Int {
        try requireOpen()
        return try backend.childCount(storageID: storageID, parentID: parentID)
    }

    func objectInfo(objectID: UInt32) throws(DeviceError) -> MTPObjectInfo {
        try requireOpen()
        return try backend.objectInfo(objectID: objectID)
    }

    func download(objectID: UInt32, to fd: Int32, progress: TransferProgress) throws(DeviceError) {
        try requireOpen()
        try backend.download(objectID: objectID, to: fd, progress: progress)
    }

    func upload(from fd: Int32, name: String, size: UInt64, modified: Date?, storageID: UInt32, parentID: UInt32,
                progress: TransferProgress) throws(DeviceError) -> UInt32 {
        try requireOpen()
        return try backend.upload(from: fd, name: name, size: size, storageID: storageID, parentID: parentID, progress: progress)
    }

    func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws(DeviceError) -> UInt32 {
        try requireOpen()
        return backend.createFolder(name: name, storageID: storageID, parentID: parentID)
    }

    func rename(objectID: UInt32, to name: String) throws(DeviceError) {
        try requireOpen()
        try backend.mutate(objectID) { $0.name = name }
    }

    func delete(objectID: UInt32) throws(DeviceError) {
        try requireOpen()
        try backend.delete(objectID: objectID)
    }

    func move(objectID: UInt32, storageID: UInt32, parentID: UInt32) throws(DeviceError) {
        try requireOpen()
        try backend.mutate(objectID) {
            $0.parentID = parentID
            $0.storageID = storageID
        }
    }

    func copy(objectID: UInt32, storageID: UInt32, parentID: UInt32) throws(DeviceError) {
        throw .unsupportedOperation
    }

    func thumbnail(objectID: UInt32) throws(DeviceError) -> Data {
        throw .objectNotFound
    }

    func readPartial(objectID: UInt32, offset: UInt64, length: UInt32) throws(DeviceError) -> Data {
        try requireOpen()
        return try backend.readPartial(objectID: objectID, offset: offset, length: length)
    }

    func beginEdit(objectID: UInt32) throws(DeviceError) {
        try requireOpen()
        try backend.beginEdit(objectID: objectID)
    }

    func sendPartial(objectID: UInt32, offset: UInt64, data: Data) throws(DeviceError) {
        try requireOpen()
        try backend.sendPartial(objectID: objectID, offset: offset, data: data)
    }

    func endEdit(objectID: UInt32) throws(DeviceError) {
        try requireOpen()
        try backend.endEdit(objectID: objectID)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        backend.recordClose()
    }

    private func requireOpen() throws(DeviceError) {
        if isClosed { throw .disconnected }
    }
}

// MARK: - Fixtures

extension USBInterfaceInfo {
    static let androidMTP = USBInterfaceInfo(number: 0, interfaceClass: 0xFF, interfaceSubClass: 0xFF, interfaceProtocol: 0x00, name: "MTP")
    static let androidADB = USBInterfaceInfo(number: 1, interfaceClass: 0xFF, interfaceSubClass: 0x42, interfaceProtocol: 0x01, name: "ADB Interface")
    static let androidPTP = USBInterfaceInfo(number: 0, interfaceClass: 0x06, interfaceSubClass: 0x01, interfaceProtocol: 0x01, name: "PTP")
    static let stillImageUnnamed = USBInterfaceInfo(number: 0, interfaceClass: 0x06, interfaceSubClass: 0x01, interfaceProtocol: 0x01, name: nil)
    static let hid = USBInterfaceInfo(number: 0, interfaceClass: 0x03, interfaceSubClass: 0x01, interfaceProtocol: 0x02, name: nil)
    static let massStorage = USBInterfaceInfo(number: 0, interfaceClass: 0x08, interfaceSubClass: 0x06, interfaceProtocol: 0x50, name: nil)
    static let hub = USBInterfaceInfo(number: 0, interfaceClass: 0x09, interfaceSubClass: 0x00, interfaceProtocol: 0x00, name: nil)
}

extension USBDeviceSnapshot {
    static func fixture(registryID: UInt64 = 1, vendorID: UInt16 = 0x18D1, productID: UInt16 = 0x4EE1,
                        serial: String? = "SERIAL1", address: UInt8 = 5, product: String? = "Pixel 8",
                        interfaces: [USBInterfaceInfo] = [.androidMTP], settled: Bool = true) -> USBDeviceSnapshot {
        USBDeviceSnapshot(registryID: registryID, vendorID: vendorID, productID: productID, vendorName: "Google",
                          productName: product, serialNumber: serial, locationID: 0x0110_0000, address: address,
                          interfaces: interfaces, interfacesSettled: settled)
    }
}

extension DeviceBroker.Configuration {
    static let fast = DeviceBroker.Configuration(reconnectGracePeriod: .milliseconds(300),
                                                 lockedPollInterval: .milliseconds(20),
                                                 openRetryDelay: .milliseconds(10),
                                                 openRetryCount: 1)
}

struct WaitTimeout: Error {}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline {
            Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
            throw WaitTimeout()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// A UserDefaults suite that starts empty for each test.
func freshDefaults(_ name: String = #function) -> UserDefaults {
    let suite = "PhoneBridgeTests.\(name).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}
