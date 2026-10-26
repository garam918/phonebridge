import Foundation
import FSKit
import Observation

enum FinderExtensionStatus: Equatable, Sendable {
    case unknown
    case notFound
    case disabled
    case enabled
    case unavailable(String)
}

enum VolumeMountState: Equatable, Sendable {
    case unmounted
    case mounting
    case mounted(URL)
    case unmounting
    case failed(String)

    var mountURL: URL? {
        if case .mounted(let url) = self { return url }
        return nil
    }
}

/// Why the last Finder mount or unmount of a volume did not work, in terms
/// the user can act on (shown with guidance instead of system error text).
enum FinderProblem: Equatable, Sendable {
    /// "PhoneBridge Finder" is off in System Settings (or not registered).
    case extensionDisabled
    /// The app's broker server for the extension is not running.
    case serverUnavailable
    /// Unmount refused: files on the volume are open.
    case filesOpen(detail: String)
    case other(detail: String)

    static func classify(mountError error: any Error, extensionStatus: FinderExtensionStatus) -> FinderProblem {
        let text = error.localizedDescription
        if extensionStatus == .disabled || extensionStatus == .notFound || text.localizedCaseInsensitiveContains("disabled") {
            return .extensionDisabled
        }
        return .other(detail: text)
    }
}

enum FinderServerStatus: Equatable, Sendable {
    case stopped
    case running(String)
    case failed(String)
}

/// What Finder integration can do on this macOS. FSKit gained the pieces
/// PhoneBridge needs over several releases.
enum FinderSupport: Equatable, Sendable {
    /// macOS 15: FSKit has no URL resources (26.0), so no PhoneBridge volume
    /// can exist. The app works without Finder.
    case unavailable
    /// macOS 26: the extension runs; volumes are mounted with `mount -F`.
    case manualMount
    /// macOS 27 and later: the app mounts and unmounts by itself.
    case full

    static var current: FinderSupport {
        if #available(macOS 27.0, *) { return .full }
        if #available(macOS 26.0, *) { return .manualMount }
        return .unavailable
    }
}

/// Mounting backend (FSKit + Foundation in the app, a fake in tests).
@MainActor
protocol VolumeMounting: AnyObject {
    var support: FinderSupport { get }
    var canMountProgrammatically: Bool { get }
    func extensionStatus() async -> FinderExtensionStatus
    func mount(_ volume: MTPFileRepository.Volume) async throws -> URL
    func unmount(_ url: URL) async throws
    /// PhoneBridge volumes already in the mount table (left by an earlier run).
    func existingMounts() -> [URL]
    @discardableResult func openExtensionSettings() -> Bool
}

extension VolumeMounting {
    var support: FinderSupport { canMountProgrammatically ? .full : .manualMount }
}

/// FSKit-backed mounter. Programmatic mounting needs macOS 27
/// (`FSClient.mountSingleVolume`); on macOS 26 the user mounts with
/// `mount -F` (shown in Settings); macOS 15 has no Finder integration.
/// FSKit is weak-linked: it does not exist before macOS 15.4.
@MainActor
final class SystemVolumeMounter: VolumeMounting {
    var support: FinderSupport { FinderSupport.current }

    var canMountProgrammatically: Bool { support == .full }

    func extensionStatus() async -> FinderExtensionStatus {
        guard #available(macOS 15.4, *) else { return .notFound }
        return await withCheckedContinuation { continuation in
            FSClient.shared.fetchInstalledExtensions { identities, error in
                if let error {
                    continuation.resume(returning: .unavailable(error.localizedDescription))
                    return
                }
                guard let module = identities?.first(where: { $0.bundleIdentifier == FinderIPC.extensionBundleIdentifier }) else {
                    continuation.resume(returning: .notFound)
                    return
                }
                continuation.resume(returning: module.isEnabled ? .enabled : .disabled)
            }
        }
    }

    func mount(_ volume: MTPFileRepository.Volume) async throws -> URL {
        guard #available(macOS 27.0, *) else { throw CocoaError(.featureUnsupported) }
        let resource = FSGenericURLResource(url: volume.address.url)
        return try await withCheckedThrowingContinuation { continuation in
            FSClient.shared.mountSingleVolume(resource: resource, bundleID: FinderIPC.extensionBundleIdentifier,
                                              options: []) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    /// Volumes mounted by `FSClient` belong to root and the sandbox may not
    /// unmount them, so the request goes to the unmount helper (V7-8). Only
    /// when the helper cannot be reached does the app try itself, which still
    /// works for volumes the user mounted with `mount -F`.
    func unmount(_ url: URL) async throws {
        do {
            try await Self.unmountWithHelper(url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {
            Log.finder.error("unmount helper unavailable (\(error.code)), unmounting in-process")
            try await FileManager.default.unmountVolume(at: url, options: [.withoutUI])
        }
    }

    func existingMounts() -> [URL] {
        VolumeUnmountPolicy.currentMounts().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func unmountWithHelper(_ url: URL) async throws {
        let connection = NSXPCConnection(serviceName: VolumeUnmountPolicy.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: VolumeUnmounting.self)
        connection.resume()
        defer { connection.invalidate() }
        let (code, message): (Int32, String?) = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) }
            guard let helper = proxy as? VolumeUnmounting else {
                continuation.resume(throwing: CocoaError(.xpcConnectionInvalid))
                return
            }
            helper.unmountVolume(atPath: url.path) { continuation.resume(returning: ($0, $1)) }
        }
        guard code == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: message ?? String(cString: strerror(code))])
        }
    }

    func openExtensionSettings() -> Bool {
        if #available(macOS 27.0, *) {
            return FSClient.shared.openFileSystemExtensionsSettings()
        }
        return false
    }

    /// Terminal command for macOS versions without programmatic mounting.
    static func manualMountCommand(for volume: MTPFileRepository.Volume, mountPoint: String) -> String {
        "mkdir -p \"\(mountPoint)\" && mount -F -t \(FinderIPC.fileSystemShortName) \"\(volume.address.url.absoluteString)\" \"\(mountPoint)\""
    }
}

/// Owns the Finder side: the IPC server, mount states, auto-mount on connect,
/// unmount on unplug and remount after reconnect.
@MainActor
@Observable
final class FinderIntegrationManager {
    private(set) var volumes: [MTPFileRepository.Volume] = []
    private(set) var states: [String: VolumeMountState] = [:]
    /// Last problem per volume, cleared by the next successful mount/unmount.
    private(set) var problems: [String: FinderProblem] = [:]
    private(set) var extensionStatus: FinderExtensionStatus = .unknown
    private(set) var serverStatus: FinderServerStatus = .stopped

    @ObservationIgnored let repository: MTPFileRepository
    @ObservationIgnored let mounter: any VolumeMounting
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let socketURLProvider: () -> URL?
    @ObservationIgnored private let demoStorages: () -> [StorageInfo]
    @ObservationIgnored private var server: FinderBrokerServer?
    /// Address each mounted volume was mounted with (detects a new session).
    @ObservationIgnored private var mountedAddresses: [String: VolumeAddress] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Finder writes that never reached a device (W3).
    let recovery: FinderWriteRecovery
    /// Called with the number of recoverable files when new ones appear.
    @ObservationIgnored var onRecoveryFound: ((Int) -> Void)?

    init(repository: MTPFileRepository, settings: AppSettings, mounter: any VolumeMounting = SystemVolumeMounter(),
         socketURLProvider: @escaping () -> URL? = FinderIPC.defaultSocketURL,
         recovery: FinderWriteRecovery = FinderWriteRecovery(directory: FinderIPC.defaultWriteBufferDirectory()),
         demoStorages: @escaping () -> [StorageInfo]) {
        self.repository = repository
        self.settings = settings
        self.mounter = mounter
        self.socketURLProvider = socketURLProvider
        self.recovery = recovery
        self.demoStorages = demoStorages
        repository.onWriteFailure = { [weak self] in
            // The extension marks the buffer as failed right after the reply.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.scanRecovery()
            }
        }
    }

    /// Looks for unsaved Finder writes and reports new ones.
    func scanRecovery() {
        let new = recovery.scan()
        if !recovery.files.isEmpty {
            Log.finder.info("unsaved Finder files: \(self.recovery.files.count) (\(new) new, \(self.recovery.files.filter(\.inUse).count) in use)")
        }
        if new > 0 { onRecoveryFound?(recovery.files.count) }
    }

    /// false on macOS versions without PhoneBridge Finder volumes (15).
    var isAvailable: Bool { mounter.support != .unavailable }
    var isEnabled: Bool { isAvailable && settings.finderIntegrationEnabled }

    func state(of volume: MTPFileRepository.Volume) -> VolumeMountState {
        states[volume.id] ?? .unmounted
    }

    // MARK: - Lifecycle

    func start() async {
        guard isAvailable else {
            Log.finder.info("Finder integration needs macOS 26 or later; not started")
            return
        }
        if isEnabled { startServer() }
        await refreshExtensionStatus()
        if isEnabled { await removeLeftoverMounts() }
        await refreshVolumes()
        scanRecovery()
    }

    /// Volumes from an earlier run (quit, crash, update) belong to sessions
    /// that no longer exist; they would only answer ESTALE.
    func removeLeftoverMounts() async {
        for url in mounter.existingMounts() {
            // A device that connected meanwhile may have reused a freed name.
            let ours = states.values.contains { $0.mountURL?.standardizedFileURL.path == url.standardizedFileURL.path }
            guard !ours else { continue }
            do {
                try await mounter.unmount(url)
                // log-privacy: public-ok — mount point under /Volumes, ASCII model name only (D31)
                Log.finder.info("removed leftover volume \(url.path, privacy: .public)")
            } catch {
                // log-privacy: public-ok — mount point under /Volumes, ASCII model name only (D31)
                Log.finder.error("leftover volume \(url.path, privacy: .public) stays: \(error.publicSummary, privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard isAvailable else { return }
        settings.finderIntegrationEnabled = enabled
        if enabled {
            startServer()
            await refreshExtensionStatus()
            await removeLeftoverMounts()
            await refreshVolumes()
        } else {
            await unmountAll()
            stopServer()
        }
    }

    func setAutoMount(_ enabled: Bool) async {
        settings.finderAutoMount = enabled
        if enabled { await refreshVolumes() }
    }

    /// Settings › Finder › "Finder에서 쓰기 허용(실험적)". The extension
    /// decides read-only or writable when it loads a volume, so mounted
    /// volumes are mounted again.
    func setWritesEnabled(_ enabled: Bool) async {
        guard settings.finderWritesEnabled != enabled else { return }
        settings.finderWritesEnabled = enabled
        repository.allowsWrites = enabled
        repository.allowsRealDeviceWrites = settings.finderWritesRealDevices
        if !enabled { await repository.writes.finishAllPendingDeletes() }
        await remountMounted()
    }

    /// Whether a volume mounted now accepts Finder writes.
    func acceptsWrites(_ volume: MTPFileRepository.Volume) -> Bool {
        settings.finderWritesEnabled && (volume.isDemo || repository.allowsRealDeviceWrites)
    }

    /// Unmounts and mounts again every volume the app mounted. A volume that
    /// cannot be unmounted (files still open) keeps its state and reports why.
    func remountMounted() async {
        let mounted = volumes.filter { mountedAddresses[$0.id] != nil }
        for volume in mounted {
            await unmount(volume)
            guard state(of: volume) == .unmounted else {
                Log.finder.error("could not remount \(volume.displayName, privacy: .private)")
                continue
            }
            await mount(volume)
        }
    }

    /// Unmounts everything and stops serving (app termination).
    func shutdown() async {
        await repository.writes.finishAllPendingDeletes()
        await unmountAll()
        stopServer()
    }

    func refreshExtensionStatus() async {
        extensionStatus = await mounter.extensionStatus()
    }

    /// Called whenever devices change. Coalesces bursts of broker events.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await self?.refreshVolumes()
        }
    }

    /// Recomputes mountable volumes; unmounts volumes whose device went away
    /// or whose session changed; auto-mounts new real-device volumes.
    func refreshVolumes() async {
        repository.includeDemoDevice = settings.showDemoDevice
        repository.allowsWrites = settings.finderWritesEnabled
        repository.allowsRealDeviceWrites = settings.finderWritesRealDevices
        repository.realDeviceWriteScope = settings.finderWriteScope
        repository.showsTemporaryObjects = settings.showStagingObjects
        let current = repository.mountableVolumes(demoStorages: settings.showDemoDevice ? demoStorages() : [])
        volumes = current
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })

        for (id, address) in mountedAddresses {
            let replacement = byID[id]
            if replacement?.address != address {
                // Device unplugged or reconnected with a new session.
                repository.invalidateCache(deviceID: address.deviceID)
                await repository.writes.finishAllPendingDeletes(deviceID: DeviceID(address.deviceID))
                await unmount(id: id)
            }
        }
        for id in states.keys where byID[id] == nil && mountedAddresses[id] == nil {
            states[id] = nil
        }

        guard isEnabled, settings.finderAutoMount else { return }
        for volume in current where !volume.isDemo || settings.autoMountDemo {
            switch state(of: volume) {
            case .unmounted: await mount(volume)
            default: break
            }
        }
    }

    // MARK: - Mount / unmount

    func mount(_ volume: MTPFileRepository.Volume) async {
        guard isEnabled else {
            states[volume.id] = .failed("disabled")
            return
        }
        if case .failed = serverStatus { startServer() }
        guard case .running = serverStatus else {
            states[volume.id] = .failed(serverFailureMessage)
            problems[volume.id] = .serverUnavailable
            return
        }
        switch state(of: volume) {
        case .mounting, .mounted, .unmounting: return
        default: break
        }
        states[volume.id] = .mounting
        do {
            let url = try await mounter.mount(volume)
            states[volume.id] = .mounted(url)
            problems[volume.id] = nil
            mountedAddresses[volume.id] = volume.address
            // log-privacy: public-ok — mount point under /Volumes, ASCII model name only (D31)
            Log.finder.info("mounted \(volume.displayName, privacy: .private) at \(url.path, privacy: .public)")
        } catch {
            states[volume.id] = .failed(error.localizedDescription)
            problems[volume.id] = FinderProblem.classify(mountError: error, extensionStatus: extensionStatus)
            Log.finder.error("mount \(volume.displayName, privacy: .private) failed: \(error.publicSummary, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    func unmount(_ volume: MTPFileRepository.Volume) async {
        await unmount(id: volume.id)
    }

    func problem(of volume: MTPFileRepository.Volume) -> FinderProblem? {
        problems[volume.id]
    }

    /// Unmounts every volume of one device ("안전하게 연결 해제"); false when
    /// one of them stays mounted (files open in Finder).
    func unmountVolumes(of deviceID: DeviceID) async -> Bool {
        let ids = mountedAddresses.filter { $0.value.deviceID == deviceID.rawValue }.map(\.key)
        for id in ids {
            await unmount(id: id)
        }
        return ids.allSatisfy { mountedAddresses[$0] == nil }
    }

    func unmountAll() async {
        for id in Array(mountedAddresses.keys) {
            await unmount(id: id)
        }
    }

    private func unmount(id: String) async {
        guard let url = states[id]?.mountURL else {
            mountedAddresses[id] = nil
            if case .mounting = states[id] {} else { states[id] = nil }
            return
        }
        states[id] = .unmounting
        do {
            try await mounter.unmount(url)
            states[id] = .unmounted
        } catch {
            // A volume whose device vanished may already be gone.
            if !FileManager.default.fileExists(atPath: url.path) {
                states[id] = .unmounted
            } else {
                // Still mounted: keep showing it as mounted, with the reason.
                states[id] = .mounted(url)
                problems[id] = .filesOpen(detail: error.localizedDescription)
                // log-privacy: public-ok — mount point under /Volumes, ASCII model name only (D31)
                Log.finder.error("unmount \(url.path, privacy: .public) failed: \(error.publicSummary, privacy: .public) \(error.localizedDescription, privacy: .private)")
                return
            }
        }
        mountedAddresses[id] = nil
        problems[id] = nil
        // The extension leaves unsaved files behind when it unmounts.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.scanRecovery()
        }
    }

    // MARK: - Server

    private var serverFailureMessage: String {
        if case .failed(let message) = serverStatus { return message }
        return "server not running"
    }

    private func startServer() {
        guard server?.isRunning != true else { return }
        guard let url = socketURLProvider() else {
            serverStatus = .failed("app-group-unavailable")
            Log.finder.error("Finder broker not started: no App Group container")
            return
        }
        let repository = repository
        let server = FinderBrokerServer(
            socketPath: url.path(percentEncoded: false),
            peerRequirement: PeerRequirement.forOwnSignature(identifiers: [FinderIPC.extensionBundleIdentifier,
                                                                            FinderIPC.appBundleIdentifier]),
            handler: { request in await repository.handle(request) })
        do {
            try server.start()
            self.server = server
            serverStatus = .running(url.path(percentEncoded: false))
        } catch {
            // EPERM inside the group container means the sandbox did not grant
            // the App Group (ad-hoc signing without a team prefix).
            serverStatus = .failed(error.code == EPERM || error.code == EACCES ? "app-group-unavailable" : error.message)
            Log.finder.error("Finder broker not started: \(error.message, privacy: .public)")
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        serverStatus = .stopped
    }
}
