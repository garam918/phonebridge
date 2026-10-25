import Foundation

/// Length-prefixed frames on a stream socket:
/// `[UInt32 BE header length][UInt32 BE body length][JSON header][raw body]`.
enum FrameIO {
    static func write(_ fd: Int32, header: Data, body: Data = Data()) throws(FinderIPCError) {
        var prefix = Data(count: 8)
        prefix.withUnsafeMutableBytes { buffer in
            buffer.storeBytes(of: UInt32(header.count).bigEndian, toByteOffset: 0, as: UInt32.self)
            buffer.storeBytes(of: UInt32(body.count).bigEndian, toByteOffset: 4, as: UInt32.self)
        }
        try writeAll(fd, prefix)
        try writeAll(fd, header)
        if !body.isEmpty { try writeAll(fd, body) }
    }

    static func read(_ fd: Int32) throws(FinderIPCError) -> (header: Data, body: Data) {
        let prefix = try readExactly(fd, count: 8)
        let headerLength = Int(prefix.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) })
        let bodyLength = Int(prefix.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) })
        guard headerLength <= FinderIPC.maxHeaderSize, bodyLength <= FinderIPC.maxBodySize else {
            throw .transport("frame too large (\(headerLength)/\(bodyLength))")
        }
        return (try readExactly(fd, count: headerLength), try readExactly(fd, count: bodyLength))
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws(FinderIPCError) {
        let failure: Int32 = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return 0
        }
        if failure != 0 { throw FinderIPCError(code: failure, message: "write: \(String(cString: strerror(failure)))") }
    }

    private static func readExactly(_ fd: Int32, count: Int) throws(FinderIPCError) -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let failure: Int32 = data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                if received == 0 { return ECONNRESET }
                if received < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += received
            }
            return 0
        }
        if failure != 0 { throw FinderIPCError(code: failure, message: "read: \(String(cString: strerror(failure)))") }
        return data
    }
}

enum UnixSocket {
    static func address(for path: String) throws(FinderIPCError) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw FinderIPCError(code: ENAMETOOLONG, message: "socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func connect(path: String) throws(FinderIPCError) -> Int32 {
        var address = try address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FinderIPCError(code: errno, message: "socket failed") }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw FinderIPCError(code: code, message: "connect: \(String(cString: strerror(code)))")
        }
        return fd
    }
}

/// Blocking client used by the FSKit extension. One request at a time per
/// client (MTP is serial anyway); reconnects once if the app restarted.
final class FinderBrokerClient: @unchecked Sendable {
    private let socketPath: String
    private let lock = NSLock()
    private var fd: Int32 = -1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    func connect() throws(FinderIPCError) {
        lock.lock()
        defer { lock.unlock() }
        try connectLocked()
    }

    func close() {
        lock.withLock {
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }
    }

    func describe(_ address: VolumeAddress) throws(FinderIPCError) -> VolumeDescription {
        guard case .volume(let description) = try send(.describe(address)).response else { throw .transport("unexpected reply") }
        return description
    }

    func list(_ address: VolumeAddress, parent: UInt32) throws(FinderIPCError) -> [RemoteEntry] {
        guard case .entries(let entries) = try send(.list(address, parent: parent)).response else { throw .transport("unexpected reply") }
        return entries
    }

    func stat(_ address: VolumeAddress, object: UInt32) throws(FinderIPCError) -> RemoteEntry {
        guard case .entry(let entry) = try send(.stat(address, object: object)).response else { throw .transport("unexpected reply") }
        return entry
    }

    func read(_ address: VolumeAddress, object: UInt32, offset: UInt64, length: Int) throws(FinderIPCError) -> Data {
        let reply = try send(.read(address, object: object, offset: offset, length: length))
        guard case .data = reply.response else { throw .transport("unexpected reply") }
        return reply.body
    }

    func writeCapabilities(_ address: VolumeAddress) throws(FinderIPCError) -> WriteCapabilities {
        guard case .writeCapabilities(let capabilities) = try send(.writeCapabilities(address)).response else {
            throw .transport("unexpected reply")
        }
        return capabilities
    }

    func createFolder(_ address: VolumeAddress, parent: UInt32, parentPath: [String]?, name: String) throws(FinderIPCError) -> RemoteEntry {
        try entry(.createFolder(address, parent: parent, parentPath: parentPath, name: name))
    }

    func commitFile(_ address: VolumeAddress, _ commit: CommitRequest) throws(FinderIPCError) -> RemoteEntry {
        try entry(.commitFile(address, commit))
    }

    func rename(_ address: VolumeAddress, object: UInt32, parent: UInt32, parentPath: [String]?, name: String,
                replacing: UInt32?) throws(FinderIPCError) -> RemoteEntry {
        try entry(.rename(address, object: object, parent: parent, parentPath: parentPath, name: name, replacing: replacing))
    }

    func move(_ address: VolumeAddress, object: UInt32, from: UInt32, fromPath: [String]?, parent: UInt32, parentPath: [String]?,
              name: String, replacing: UInt32?) throws(FinderIPCError) -> RemoteEntry {
        try entry(.move(address, object: object, from: from, fromPath: fromPath, parent: parent, parentPath: parentPath, name: name,
                        replacing: replacing))
    }

    func delete(_ address: VolumeAddress, object: UInt32, parent: UInt32, parentPath: [String]?) throws(FinderIPCError) {
        guard case .done = try send(.delete(address, object: object, parent: parent, parentPath: parentPath)).response else {
            throw .transport("unexpected reply")
        }
    }

    private func entry(_ request: FinderRequest) throws(FinderIPCError) -> RemoteEntry {
        guard case .entry(let entry) = try send(request).response else { throw .transport("unexpected reply") }
        return entry
    }

    /// Sends one request; `.failure` responses are thrown.
    func send(_ request: FinderRequest) throws(FinderIPCError) -> (response: FinderResponse, body: Data) {
        // NSLock.withLock is untyped-rethrows; lock manually to keep typed throws.
        lock.lock()
        defer { lock.unlock() }
        var delivered = false
        do throws(FinderIPCError) {
            return try exchangeLocked(request, delivered: &delivered)
        } catch where error.code == EPIPE || error.code == ECONNRESET || error.code == EBADF {
            // The app may have restarted its server; try a fresh connection
            // once. A write whose reply was lost may already have happened,
            // so it is not sent twice.
            resetLocked()
            guard request.isIdempotent || !delivered else { throw error }
            try connectLocked()
            var again = false
            return try exchangeLocked(request, delivered: &again)
        }
    }

    private func connectLocked() throws(FinderIPCError) {
        if fd >= 0 { return }
        let socket = try UnixSocket.connect(path: socketPath)
        fd = socket
        do throws(FinderIPCError) {
            var delivered = false
            guard case .hello(let version) = try exchangeLocked(.hello(version: FinderIPC.protocolVersion), delivered: &delivered).response,
                  version == FinderIPC.protocolVersion else {
                throw FinderIPCError(code: EPROTONOSUPPORT, message: "protocol version mismatch")
            }
        } catch {
            resetLocked()
            throw error
        }
    }

    /// Drops the connection; the next request opens a new one.
    private func resetLocked() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// `delivered` becomes true once the request is fully written.
    private func exchangeLocked(_ request: FinderRequest, delivered: inout Bool) throws(FinderIPCError) -> (response: FinderResponse, body: Data) {
        if fd < 0 { try connectLocked() }
        let header: Data
        do {
            header = try JSONEncoder().encode(request)
        } catch {
            throw FinderIPCError(code: EINVAL, message: "encode: \(error)")
        }
        var response: FinderResponse
        var body: Data
        do throws(FinderIPCError) {
            try FrameIO.write(fd, header: header)
            delivered = true
            let frame = try FrameIO.read(fd)
            response = try Self.decode(frame.header)
            body = frame.body
            if case .encodedInBody = response {
                response = try Self.decode(body)
                body = Data()
            }
        } catch {
            // Whatever is left of this exchange on the socket (an oversized or
            // unreadable frame) would be read as the next reply: start over.
            resetLocked()
            throw error
        }
        if case .failure(let failure) = response { throw failure }
        return (response, body)
    }

    private static func decode(_ data: Data) throws(FinderIPCError) -> FinderResponse {
        do {
            return try JSONDecoder().decode(FinderResponse.self, from: data)
        } catch {
            throw FinderIPCError(code: EPROTO, message: "decode: \(error)")
        }
    }
}
