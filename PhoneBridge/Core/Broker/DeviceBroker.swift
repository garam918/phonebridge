import Foundation
import Observation

/// Everything the UI may know about one real USB device.
struct DeviceRecord: Identifiable, Equatable, Sendable {
    let id: DeviceID
    var usb: USBDeviceSnapshot
    var state: ConnectionState
    var info: MTPDeviceInfo?
    var storages: [StorageInfo]
    var capabilities: MTPCapabilities = []
    /// Bumped whenever a session is created or torn down. File system handles
    /// and object ids are only valid for the generation that produced them.
    var generation: UInt64

    var displayName: String {
        if let friendly = info?.friendlyName, !friendly.isEmpty { return friendly }
        let parts = [info?.manufacturer, info?.model].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return usb.displayName
    }
}

struct DeviceChange: Sendable {
    let id: DeviceID
    let previousState: ConnectionState?
    /// nil when the record was removed.
    let record: DeviceRecord?
}

/// Single owner of USB device state and MTP sessions.
///
/// Runs on the main actor but never blocks it: all USB/MTP I/O happens inside
/// `MTPDeviceSession` actors (one serial queue per device). The UI reads
/// `devices`, calls `retry`/`refreshStorages`, and browses through the
/// `DeviceFileSystem` handed out by `fileSystem(for:)`. It never calls libmtp.
@MainActor
@Observable
final class DeviceBroker {
    struct Configuration: Sendable {
        /// How long a vanished device is kept as `.reconnecting` (mode switches
        /// re-enumerate the device) before it is dropped.
        var reconnectGracePeriod: Duration = .seconds(8)
        /// Poll interval for storage while the device is locked.
        var lockedPollInterval: Duration = .seconds(2)
        var openRetryDelay: Duration = .seconds(1)
        /// Extra automatic attempts after a failed session open.
        var openRetryCount = 1

        static let standard = Configuration()
    }

    private(set) var devices: [DeviceRecord] = []

    @ObservationIgnored var onChange: ((DeviceChange) -> Void)?

    @ObservationIgnored private let monitor: any USBDeviceMonitoring
    @ObservationIgnored private let backend: any MTPBackend
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private var sessions: [DeviceID: MTPDeviceSession] = [:]
    @ObservationIgnored private var workers: [DeviceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var graceTimers: [DeviceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    /// Starts at the launch time in milliseconds, so a Finder volume left over
    /// from an earlier run can never match a session of this run.
    @ObservationIgnored private var generationCounter = UInt64(Date().timeIntervalSince1970 * 1000)
    /// Fresh-session retries after "device not found" right after plug-in.
    @ObservationIgnored private var transientRetries: [DeviceID: Int] = [:]
    static let maxTransientRetries = 2

    init(monitor: any USBDeviceMonitoring, backend: any MTPBackend, configuration: Configuration = .standard) {
        self.monitor = monitor
        self.backend = backend
        self.configuration = configuration
    }

    // MARK: - Public API

    func start() {
        guard eventTask == nil else { return }
        let events = monitor.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        monitor.start()
        Log.broker.info("DeviceBroker started")
    }

    /// Closes every session; call before the app terminates.
    func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        monitor.stop()
        graceTimers.values.forEach { $0.cancel() }
        graceTimers.removeAll()
        workers.values.forEach { $0.cancel() }
        workers.removeAll()
        let open = Array(sessions.values)
        sessions.removeAll()
        for session in open {
            await session.close()
        }
        Log.broker.info("DeviceBroker shut down, closed \(open.count) session(s)")
    }

    func record(for id: DeviceID) -> DeviceRecord? {
        devices.first { $0.id == id }
    }

    /// A browsing handle for a connected device, bound to the current session.
    func fileSystem(for id: DeviceID) -> (any DeviceFileSystem)? {
        guard let record = record(for: id), record.state.isMTPReady, let session = sessions[id] else { return nil }
        return MTPDeviceFileSystem(deviceID: id, generation: record.generation, session: session,
                                   capabilities: record.capabilities.fileSystemCapabilities)
    }

    /// User-initiated retry: re-evaluates the USB descriptors and reconnects.
    func retry(_ id: DeviceID) {
        guard let record = record(for: id) else { return }
        Log.broker.info("\(id, privacy: .private(mask: .hash)) retry requested in state \(record.state.name, privacy: .public)")
        transientRetries[id] = nil
        apply(USBDeviceClassifier.classify(record.usb), to: id)
    }

    /// "안전하게 연결 해제": closes the MTP session so the cable can be pulled.
    /// The device stays listed until it is unplugged; `retry` reconnects, and
    /// so does plugging it in again.
    func safelyDisconnect(_ id: DeviceID) async {
        guard let record = record(for: id), record.state.isUSBPresent, record.state != .safelyDisconnected else { return }
        transientRetries[id] = nil
        workers.removeValue(forKey: id)?.cancel()
        let session = sessions.removeValue(forKey: id)
        let generation = nextGeneration()
        update(id) {
            $0.state = .safelyDisconnected
            $0.storages = []
            $0.generation = generation
        }
        await session?.close()
        Log.broker.info("\(id, privacy: .private(mask: .hash)) safely disconnected")
    }

    /// Re-reads storage info (free space, SD card inserted/removed).
    func refreshStorages(_ id: DeviceID) {
        guard let record = record(for: id), record.state.isMTPReady, let session = sessions[id] else { return }
        let generation = record.generation
        workers[id]?.cancel()
        workers[id] = Task { [weak self] in
            await self?.reloadStorages(id: id, session: session, generation: generation)
        }
    }

    /// A refresh of a working connection keeps it unless the device is gone:
    /// a GetStorageInfo error or an empty answer (an SD card being removed)
    /// must not close the session and cancel queued transfers.
    private func reloadStorages(id: DeviceID, session: MTPDeviceSession, generation: UInt64) async {
        do throws(DeviceError) {
            let storages = try await session.storages()
            guard isCurrent(id, generation), !storages.isEmpty else { return }
            update(id) { $0.storages = storages }
        } catch {
            guard isCurrent(id, generation) else { return }
            if case .disconnected = error {
                fail(id, error)
            } else {
                Log.broker.notice("\(id, privacy: .private(mask: .hash)) storage refresh failed, keeping the session: \(error.localizationKey, privacy: .public)")
            }
        }
    }

    // MARK: - USB events

    private func handle(_ event: USBEvent) {
        switch event {
        case .attached(let snapshot): upsert(snapshot)
        case .detached(let registryID): detach(registryID: registryID)
        }
    }

    private func upsert(_ snapshot: USBDeviceSnapshot) {
        let classification = USBDeviceClassifier.classify(snapshot)
        let id = snapshot.logicalID

        guard let previous = record(for: id) else {
            guard classification != .ignored else { return }
            Log.broker.info("""
                new device \(id, privacy: .private(mask: .hash)) \(snapshot.idPairDescription, privacy: .public) \
                \(snapshot.displayName, privacy: .public) class=\(String(describing: classification), privacy: .public)
                """)
            insert(DeviceRecord(id: id, usb: snapshot, state: .usbDetected, info: nil, storages: [], generation: 0))
            apply(classification, to: id)
            return
        }

        cancelGraceTimer(id)
        let sameEnumeration = previous.usb.registryID == snapshot.registryID
        if sameEnumeration && previous.usb == snapshot { return }
        update(id) { $0.usb = snapshot }

        // The user disconnected it; only a new plug-in (or 다시 연결) reconnects.
        if sameEnumeration && previous.state == .safelyDisconnected { return }
        // Interface notifications for a device we are already talking to are
        // side effects of our own session (or of the OS); don't restart it.
        if sameEnumeration && sessions[id] != nil {
            switch previous.state {
            case .connecting, .connected, .waitingForMTP(.deviceLocked): return
            default: break
            }
        }
        if classification == .ignored { return }
        apply(classification, to: id)
    }

    private func detach(registryID: UInt64) {
        guard let record = devices.first(where: { $0.usb.registryID == registryID }) else { return }
        let id = record.id
        transientRetries[id] = nil
        tearDownSession(id)

        if case .unsupported = record.state {
            remove(id)
            return
        }
        update(id) {
            $0.state = .reconnecting
            $0.storages = []
        }
        let grace = configuration.reconnectGracePeriod
        graceTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self?.expire(id)
        }
    }

    private func expire(_ id: DeviceID) {
        graceTimers[id] = nil
        guard record(for: id)?.state == .reconnecting else { return }
        update(id) { $0.state = .disconnected }
        remove(id)
    }

    // MARK: - Connection state machine

    private func apply(_ classification: USBDeviceClass, to id: DeviceID) {
        switch classification {
        case .ignored:
            return
        case .pending:
            tearDownSession(id)
            update(id) { $0.state = .usbDetected }
        case .androidWithoutMTP:
            tearDownSession(id)
            update(id) {
                $0.state = .waitingForMTP(.fileTransferModeRequired)
                $0.storages = []
            }
        case .androidPTPMode:
            tearDownSession(id)
            update(id) {
                $0.state = .waitingForMTP(.ptpModeSelected)
                $0.storages = []
            }
        case .unsupported(let reason):
            tearDownSession(id)
            update(id) { $0.state = .unsupported(reason) }
        case .mtpCandidate:
            connect(id)
        }
    }

    private func connect(_ id: DeviceID) {
        guard let record = record(for: id) else { return }
        tearDownSession(id)
        let generation = nextGeneration()
        let session = MTPDeviceSession(target: MTPTarget(snapshot: record.usb), backend: backend,
                                       label: "\(record.usb.idPairDescription)-\(generation)")
        sessions[id] = session
        update(id) {
            $0.state = .connecting
            $0.generation = generation
            $0.storages = []
        }
        workers[id] = Task { [weak self] in
            await self?.runConnection(id: id, session: session, generation: generation)
        }
    }

    private func runConnection(id: DeviceID, session: MTPDeviceSession, generation: UInt64) async {
        var attempt = 0
        openLoop: while true {
            do throws(DeviceError) {
                let opened = try await session.open()
                guard isCurrent(id, generation) else { return }
                update(id) {
                    $0.info = opened.info
                    $0.capabilities = opened.capabilities
                }
                break openLoop
            } catch {
                guard isCurrent(id, generation), !Task.isCancelled else { return }
                switch error {
                case .deviceBusy:
                    let registryID = record(for: id)?.usb.registryID ?? 0
                    let owner = await monitor.exclusiveOwner(registryID: registryID)
                    guard isCurrent(id, generation) else { return }
                    fail(id, .deviceBusy(owner: owner))
                    return
                case .noMTPInterface:
                    fail(id, error)
                    return
                case .disconnected:
                    // Seen on a real Samsung right after plug-in: the phone
                    // re-enumerates and libusb does not see the address IOKit
                    // reported yet. Retry with a new session built from the
                    // latest USB snapshot instead of failing.
                    let retries = transientRetries[id, default: 0]
                    guard retries < Self.maxTransientRetries else {
                        fail(id, error)
                        return
                    }
                    transientRetries[id] = retries + 1
                    Log.broker.notice("\(id, privacy: .private(mask: .hash)) not reachable yet, fresh session retry \(retries + 1)")
                    try? await Task.sleep(for: configuration.openRetryDelay)
                    guard isCurrent(id, generation), !Task.isCancelled else { return }
                    connect(id)
                    return
                default:
                    guard attempt < configuration.openRetryCount else {
                        fail(id, error)
                        return
                    }
                    attempt += 1
                    Log.broker.notice("\(id, privacy: .private(mask: .hash)) open failed (\(error.localizationKey, privacy: .public)), retry \(attempt)")
                    try? await Task.sleep(for: configuration.openRetryDelay)
                    guard isCurrent(id, generation), !Task.isCancelled else { return }
                }
            }
        }
        await loadStorages(id: id, session: session, generation: generation)
    }

    /// Reads storages; while the device reports none (locked screen or the
    /// "allow access" prompt pending) it stays in `.waitingForMTP(.deviceLocked)`
    /// and polls until storage shows up or the device goes away.
    private func loadStorages(id: DeviceID, session: MTPDeviceSession, generation: UInt64) async {
        while !Task.isCancelled {
            do throws(DeviceError) {
                let storages = try await session.storages()
                guard isCurrent(id, generation) else { return }
                if storages.isEmpty {
                    update(id) {
                        $0.state = .waitingForMTP(.deviceLocked)
                        $0.storages = []
                    }
                } else {
                    transientRetries[id] = nil
                    update(id) {
                        $0.storages = storages
                        $0.state = .connected
                    }
                    return
                }
            } catch {
                guard isCurrent(id, generation) else { return }
                fail(id, error)
                return
            }
            try? await Task.sleep(for: configuration.lockedPollInterval)
        }
    }

    private func fail(_ id: DeviceID, _ error: DeviceError) {
        Log.broker.error("\(id, privacy: .private(mask: .hash)) failed: \(error.localizationKey, privacy: .public) \(error.logDetail ?? "", privacy: .public)")
        if let session = sessions.removeValue(forKey: id) {
            Task { await session.close() }
        }
        update(id) {
            $0.state = .failed(error)
            $0.storages = []
        }
    }

    // MARK: - Bookkeeping

    private func isCurrent(_ id: DeviceID, _ generation: UInt64) -> Bool {
        record(for: id)?.generation == generation
    }

    private func nextGeneration() -> UInt64 {
        generationCounter += 1
        return generationCounter
    }

    /// Cancels the worker, closes the session off the main actor and moves the
    /// record to a fresh generation so late results are discarded.
    private func tearDownSession(_ id: DeviceID) {
        workers.removeValue(forKey: id)?.cancel()
        if let session = sessions.removeValue(forKey: id) {
            Task { await session.close() }
        }
        let generation = nextGeneration()
        update(id) { $0.generation = generation }
    }

    private func cancelGraceTimer(_ id: DeviceID) {
        graceTimers.removeValue(forKey: id)?.cancel()
    }

    private func insert(_ record: DeviceRecord) {
        devices.append(record)
        onChange?(DeviceChange(id: record.id, previousState: nil, record: record))
    }

    private func remove(_ id: DeviceID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        let removed = devices.remove(at: index)
        cancelGraceTimer(id)
        Log.broker.info("\(id, privacy: .private(mask: .hash)) removed")
        onChange?(DeviceChange(id: id, previousState: removed.state, record: nil))
    }

    private func update(_ id: DeviceID, _ mutate: (inout DeviceRecord) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        let before = devices[index]
        var after = before
        mutate(&after)
        guard after != before else { return }
        devices[index] = after
        if before.state != after.state {
            Log.broker.info("\(id, privacy: .private(mask: .hash)) \(before.state.name, privacy: .public) → \(after.state.name, privacy: .public)")
        }
        onChange?(DeviceChange(id: id, previousState: before.state, record: after))
    }
}
