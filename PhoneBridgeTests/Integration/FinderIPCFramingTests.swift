import Foundation
import Synchronization
import Testing
@testable import PhoneBridge

/// Large replies and broken frames on the Finder broker socket (audit
/// 2026-10-23, M1): before, a folder with more than ~35,000 items made a
/// reply too large for the header, and the unread rest of it broke every
/// later request on that connection until the volume was remounted.
@MainActor
@Suite("Finder IPC framing", .serialized)
final class FinderIPCFramingTests {
    static let folderID: UInt32 = 0x8_0000
    static let itemCount = 45_000

    let socketURL = shortSocketURL()

    /// Client calls block; run them off the main actor the repository needs.
    private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached { try body() }.value
    }

    private static func bigDevice() -> MockDeviceFileSystem {
        let storage = MockDeviceFileSystem.internalStorageID
        var nodes: [MockDeviceFileSystem.Node] = [
            .init(objectID: folderID, storageID: storage, parentID: FileItemID.rootObjectID, name: "Camera", isFolder: true),
        ]
        for index in 0..<itemCount {
            nodes.append(.init(objectID: 0x9_0000 + UInt32(index), storageID: storage, parentID: folderID,
                               name: String(format: "IMG_20261023_%06d.jpg", index), isFolder: false,
                               size: UInt64(2_000_000 + index), modified: Date(timeIntervalSince1970: 1_790_000_000)))
        }
        return MockDeviceFileSystem(nodes: nodes)
    }

    @Test func folderTooLargeForAHeaderIsListedAndTheConnectionStaysUsable() async throws {
        let repository = MTPFileRepository(broker: DeviceBroker(monitor: MockUSBMonitor(), backend: MockMTPBackend()),
                                           demoDevice: Self.bigDevice(), demoName: { "Demo" },
                                           cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "PBFraming-\(UUID().uuidString)"))
        let server = FinderBrokerServer(socketPath: socketURL.path,
                                        peerRequirement: PeerRequirement.forOwnSignature(identifiers: [FinderIPC.appBundleIdentifier])) {
            await repository.handle($0)
        }
        try server.start()
        defer { server.stop() }
        let path = socketURL.path
        let address = VolumeAddress(deviceID: DeviceID.demo.rawValue, storageID: MockDeviceFileSystem.internalStorageID, generation: 1)
        let folder = Self.folderID
        let (count, root) = try await offMain {
            let client = FinderBrokerClient(socketPath: path)
            let camera = try client.list(address, parent: folder)
            return (camera.count, try client.list(address, parent: remoteRootObjectID))
        }
        #expect(count == Self.itemCount)
        #expect(root.map(\.name) == ["Camera"], "the same connection answers the next request")
    }

    @Test func oversizedRepliesMoveIntoTheBody() throws {
        let entries = (0..<70_000).map { RemoteEntry(objectID: UInt32($0), parentID: 1, name: "IMG_\($0).jpg", isFolder: false,
                                                     size: 1, modified: nil) }
        let (header, body) = try #require(FinderBrokerServer.frame(.entries(entries), body: Data()))
        #expect(header.count <= FinderIPC.maxHeaderSize && body.count > FinderIPC.maxHeaderSize)
        #expect(try JSONDecoder().decode(FinderResponse.self, from: header) == .encodedInBody)
        #expect(try JSONDecoder().decode(FinderResponse.self, from: body) == .entries(entries))
        let small = try #require(FinderBrokerServer.frame(.done, body: Data("x".utf8)))
        #expect(try JSONDecoder().decode(FinderResponse.self, from: small.header) == .done && small.body == Data("x".utf8))
    }

    @Test func clientStartsOverAfterAFrameItCannotRead() async throws {
        let server = try BrokenFrameServer(path: socketURL.path)
        defer { server.stop() }
        let path = socketURL.path
        let address = VolumeAddress(deviceID: "demo", storageID: 1, generation: 1)
        let (first, second, third) = try await offMain {
            let client = FinderBrokerClient(socketPath: path)
            let first = Result { try client.list(address, parent: remoteRootObjectID) }
            let second = Result { try client.list(address, parent: remoteRootObjectID) }
            let third = Result { try client.list(address, parent: remoteRootObjectID) }
            return (first, second, third)
        }
        #expect((try? first.get()) == nil, "the oversized frame is refused")
        #expect((try? second.get()) == [], "the next request does not read the leftovers of the bad frame")
        #expect((try? third.get()) == [])
        #expect(server.connections == 2)
    }
}

/// Answers `hello`, then replies to the first other request with a frame
/// whose header is over the limit, followed by bytes that look like garbage.
private final class BrokenFrameServer: @unchecked Sendable {
    private let path: String
    private let listenFD: Int32
    private let state = Mutex((broken: false, connections: 0))

    var connections: Int { state.withLock { $0.connections } }

    init(path: String) throws {
        self.path = path
        var address = try UnixSocket.address(for: path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 4) == 0 else { throw FinderIPCError(code: errno, message: "test server") }
        listenFD = fd
        Thread { [self] in acceptLoop() }.start()
    }

    func stop() {
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            state.withLock { $0.connections += 1 }
            Thread { [self] in serve(client) }.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        let encoder = JSONEncoder()
        while let frame = try? FrameIO.read(fd), let request = try? JSONDecoder().decode(FinderRequest.self, from: frame.header) {
            if case .hello(let version) = request {
                guard (try? FrameIO.write(fd, header: try encoder.encode(FinderResponse.hello(version: version)))) != nil else { return }
                continue
            }
            if state.withLock({ state in defer { state.broken = true }; return !state.broken }) {
                var prefix = Data()
                withUnsafeBytes(of: UInt32(FinderIPC.maxHeaderSize + 1).bigEndian) { prefix.append(contentsOf: $0) }
                withUnsafeBytes(of: UInt32(0).bigEndian) { prefix.append(contentsOf: $0) }
                let raw = prefix + Data(repeating: 0x41, count: 4_096)
                _ = raw.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                continue
            }
            guard let reply = try? encoder.encode(FinderResponse.entries([])),
                  (try? FrameIO.write(fd, header: reply)) != nil else { return }
        }
    }
}
