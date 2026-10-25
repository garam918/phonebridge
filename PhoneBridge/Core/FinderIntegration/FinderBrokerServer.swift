import Foundation
import Synchronization

/// Unix-socket server in the App Group container. Every Finder request is
/// handed to `handler` (the MTP file repository on the main actor), so the
/// FSKit extension never touches libmtp or opens its own MTP session.
final class FinderBrokerServer: @unchecked Sendable {
    typealias Handler = @Sendable (FinderRequest) async -> (FinderResponse, Data)

    let socketPath: String
    private let handler: Handler
    /// Code-signing requirement every client must satisfy (`PeerRequirement`);
    /// nil refuses every client.
    private let peerRequirement: String?
    private let state = Mutex<(listenFD: Int32, clients: Set<Int32>, running: Bool)>((-1, [], false))

    init(socketPath: String, peerRequirement: String?, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.peerRequirement = peerRequirement
        self.handler = handler
        if peerRequirement == nil { Log.finder.error("Finder broker has no client requirement; every client is refused") }
    }

    deinit {
        stop()
    }

    var isRunning: Bool { state.withLock { $0.running } }

    func start() throws(FinderIPCError) {
        guard !isRunning else { return }
        var address = try UnixSocket.address(for: socketPath)
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FinderIPCError(code: errno, message: "socket failed") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw FinderIPCError(code: code, message: "bind/listen: \(String(cString: strerror(code)))")
        }
        state.withLock {
            $0.listenFD = fd
            $0.running = true
        }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "PhoneBridge.FinderBroker.accept"
        thread.start()
        Log.finder.info("Finder broker listening at \(self.socketPath, privacy: .private)")
    }

    func stop() {
        let (listenFD, clients) = state.withLock { state -> (Int32, Set<Int32>) in
            let snapshot = (state.listenFD, state.clients)
            state.listenFD = -1
            state.clients = []
            state.running = false
            return snapshot
        }
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            unlink(socketPath)
        }
        for client in clients {
            shutdown(client, SHUT_RDWR)
        }
    }

    // MARK: - Connections

    private func acceptLoop(_ listenFD: Int32) {
        while isRunning {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                break
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            guard validatePeer(client) else {
                Log.finder.error("rejected Finder broker client (uid or code signature mismatch)")
                close(client)
                continue
            }
            state.withLock { _ = $0.clients.insert(client) }
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "PhoneBridge.FinderBroker.client"
            thread.start()
        }
    }

    /// Each client is served on its own thread; requests on one connection
    /// are strictly sequential.
    private func serve(_ fd: Int32) {
        defer {
            state.withLock { _ = $0.clients.remove(fd) }
            close(fd)
        }
        while true {
            let frame: (header: Data, body: Data)
            do {
                frame = try FrameIO.read(fd)
            } catch {
                return
            }
            let (response, body) = respond(to: frame.header)
            guard let (header, payload) = Self.frame(response, body: body) else { return }
            do {
                try FrameIO.write(fd, header: header, body: payload)
            } catch {
                return
            }
        }
    }

    /// Header and body for `response`. A response too large for the header
    /// goes into the body (64 MiB, about half a million folder entries); one
    /// too large even for that is answered with EFBIG instead of a frame the
    /// client cannot read.
    static func frame(_ response: FinderResponse, body: Data) -> (header: Data, body: Data)? {
        let encoder = JSONEncoder()
        guard let header = try? encoder.encode(response) else { return nil }
        if header.count <= FinderIPC.maxHeaderSize { return (header, body) }
        if body.isEmpty, header.count <= FinderIPC.maxBodySize, let marker = try? encoder.encode(FinderResponse.encodedInBody) {
            return (marker, header)
        }
        let failure = FinderResponse.failure(FinderIPCError(code: EFBIG, message: "response too large (\(header.count) bytes)"))
        return (try? encoder.encode(failure)).map { ($0, Data()) }
    }

    private func respond(to header: Data) -> (FinderResponse, Data) {
        guard let request = try? JSONDecoder().decode(FinderRequest.self, from: header) else {
            return (.failure(FinderIPCError(code: EPROTO, message: "malformed request")), Data())
        }
        if case .hello(let version) = request {
            return version == FinderIPC.protocolVersion
                ? (.hello(version: FinderIPC.protocolVersion), Data())
                : (.failure(FinderIPCError(code: EPROTONOSUPPORT, message: "protocol \(version) unsupported")), Data())
        }
        // Bridge the blocking connection thread to the async repository.
        let result = Mutex<(FinderResponse, Data)?>(nil)
        let done = DispatchSemaphore(value: 0)
        let handler = handler
        Task {
            let value = await handler(request)
            result.withLock { $0 = value }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 } ?? (.failure(.transport("no response")), Data())
    }

    // MARK: - Peer validation

    /// Same user, and a valid code signature that satisfies `peerRequirement`
    /// (the PhoneBridge extension or app, signed by this build's team).
    private func validatePeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let peerRequirement, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }

        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        return PeerRequirement.isSatisfied(by: token, requirement: peerRequirement)
    }
}
