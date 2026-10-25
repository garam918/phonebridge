import AppKit
import Foundation
import Observation

enum SidebarItem: Hashable, Sendable {
    case device(DeviceID)
    case storage(DeviceID, UInt32)

    var deviceID: DeviceID {
        switch self {
        case .device(let id), .storage(let id, _): id
        }
    }

    var storageID: UInt32? {
        if case .storage(_, let storageID) = self { return storageID }
        return nil
    }
}

enum DetailContent: Equatable {
    case welcome
    case deviceState(DeviceRecord)
    case browser
}

/// Transient status-bar message. Localized at display time so it follows a
/// language switch.
struct AppNotice: Equatable, Identifiable {
    enum Kind: Equatable {
        case deviceConnected(String)
        case deviceDisconnected(String)
        case connectionFailed(String)
        /// Files written in Finder that did not reach the device.
        case finderRecovery(Int)
        case safelyDisconnected(String)
        /// Safe disconnect refused: files are open in Finder.
        case disconnectBlocked
        /// First item name and number of items.
        case transferCompleted(String, Int)
        case transferFailed(String, Int)
        case diagnosticsExported
    }

    let id = UUID()
    let kind: Kind
}

/// Composition root and UI coordinator. Owns the long-lived services
/// (dependency injection happens here) and keeps the browser in sync with the
/// broker's device state.
@MainActor
@Observable
final class AppModel {
    let broker: DeviceBroker
    let localization: LocalizationManager
    let settings: AppSettings
    let browser: BrowserViewModel
    let demoDevice: MockDeviceFileSystem
    let transfers: TransferManager
    /// Downloads device items dragged to Finder or another app.
    let dragExporter: DeviceDragExporter
    let local: LocalBrowserViewModel
    let localAccess: LocalAccessManager
    let previews: PreviewService
    let finder: FinderIntegrationManager
    /// Hidden objects in flight on devices, swept in their next session (W3).
    let journal: DeviceLeftoverJournal

    /// Internal clipboard for copy / cut / paste of files.
    var clipboard: FileClipboard?
    var activeDialog: FileDialog?
    /// Shown as an alert (create / rename failures, unsupported actions).
    var operationError: DeviceError?

    private(set) var demoStorages: [StorageInfo] = []
    private(set) var notice: AppNotice?
    var showInspector = true
    var isTransferPanelExpanded = false
    /// First-run guide (also from Help › Getting Started).
    var showOnboarding = false
    /// Help › Connection Troubleshooting.
    var showTroubleshooting = false
    /// Bumped by File › Find (⌘F) to focus the search field.
    var searchFocusRequest = 0
    var sidebarSelection: SidebarItem? {
        didSet {
            if sidebarSelection != oldValue { syncBrowser() }
        }
    }

    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// The selection payload of the drag in progress: SwiftUI asks every
    /// dragged row for its item, and they all carry the same selection.
    @ObservationIgnored var dragPayloadCache: (key: DragPayloadKey, payload: DragPayload)?

    init(broker: DeviceBroker, localization: LocalizationManager, settings: AppSettings,
         demoDevice: MockDeviceFileSystem = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree() + MockDeviceFileSystem.demoExtras()),
         localVolume: any LocalVolumeInspecting = SystemLocalVolume(),
         localAccess: LocalAccessManager = LocalAccessManager(),
         previews: PreviewService = PreviewService(),
         volumeMounter: (any VolumeMounting)? = nil,
         finderSocketURL: @escaping () -> URL? = FinderIPC.defaultSocketURL,
         journal: DeviceLeftoverJournal = DeviceLeftoverJournal(fileURL: nil),
         localJournal: LocalStagingJournal = LocalStagingJournal(fileURL: nil),
         dragDirectory: URL? = nil) {
        self.broker = broker
        self.localization = localization
        self.settings = settings
        self.demoDevice = demoDevice
        self.localAccess = localAccess
        self.previews = previews
        self.journal = journal
        browser = BrowserViewModel()
        browser.sort.foldersFirst = settings.foldersFirst
        local = LocalBrowserViewModel()
        local.sort.foldersFirst = settings.foldersFirst
        transfers = TransferManager(fileSystemProvider: { id in
            id == .demo ? demoDevice : broker.fileSystem(for: id)
        }, volume: localVolume, journal: journal, localJournal: localJournal)
        let transfers = transfers
        dragExporter = dragDirectory.map { DeviceDragExporter(transfers: transfers, directory: $0) }
            ?? DeviceDragExporter(transfers: transfers)
        let repository = MTPFileRepository(broker: broker, demoDevice: demoDevice,
                                           demoName: { localization.t("demo.deviceName") },
                                           writes: FinderWriteCoordinator(bufferDirectory: FinderIPC.defaultWriteBufferDirectory(),
                                                                          journal: journal))
        var demoStorageList: () -> [StorageInfo] = { [] }
        finder = FinderIntegrationManager(repository: repository, settings: settings,
                                          mounter: volumeMounter ?? SystemVolumeMounter(),
                                          socketURLProvider: finderSocketURL,
                                          demoStorages: { demoStorageList() })
        broker.onChange = { [weak self] change in
            self?.handle(change)
        }
        demoStorageList = { [weak self] in self?.demoStorages ?? [] }
        transfers.onJobFinished = { [weak self] job in
            self?.transferFinished(job)
        }
        finder.onRecoveryFound = { [weak self] count in
            self?.post(.finderRecovery(count))
        }
    }

    /// Production wiring: IOKit hot-plug monitor + libmtp backend.
    static func live() -> AppModel {
        let broker = DeviceBroker(monitor: IOKitUSBMonitor(), backend: LibMTPBackend())
        let settings = AppSettings()
        let demo = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree() + MockDeviceFileSystem.demoExtras())
        demo.configureFaults { faults in
            // The demo keeps uploaded bytes in memory; big test copies keep only their size.
            faults.maxStoredContentSize = 512 << 20
            if settings.demoUploadRate > 0 {
                faults.chunkSize = 1 << 20
                faults.chunkDelay = .seconds(1 / settings.demoUploadRate)
            }
        }
        return AppModel(broker: broker, localization: LocalizationManager(), settings: settings, demoDevice: demo,
                        journal: DeviceLeftoverJournal(fileURL: DeviceLeftoverJournal.defaultFileURL),
                        localJournal: LocalStagingJournal(fileURL: LocalStagingJournal.defaultFileURL))
    }

    /// Hosted unit tests run inside the app process; they get a model whose
    /// broker never touches real USB hardware.
    static func inert() -> AppModel {
        let broker = DeviceBroker(monitor: InertUSBMonitor(), backend: InertMTPBackend())
        return AppModel(broker: broker, localization: LocalizationManager(), settings: AppSettings())
    }

    func start(startBroker: Bool = true) async {
        guard !started else { return }
        started = true
        if startBroker {
            Log.app.info("libmtp \(LibMTPBackend.libmtpVersion, privacy: .public)")
            broker.start()
        }
        previews.purgeCache()
        dragExporter.removeOld(olderThan: 0)
        transfers.localJournal.sweep()
        demoStorages = (try? await demoDevice.storages()) ?? []
        await journal.sweep(demoDevice)
        // The Mac pane is listed only when it is visible.
        if settings.dualPane {
            await local.open(root: localAccess.restoreLastFolder() ?? localAccess.defaultFolder)
        }
        await finder.start()
        if !settings.onboardingCompleted { showOnboarding = true }
        if sidebarSelection == nil, settings.showDemoDevice, broker.devices.isEmpty, let first = demoStorages.first {
            sidebarSelection = .storage(.demo, first.id)
        }
    }

    // MARK: - Derived state

    var selectedRecord: DeviceRecord? {
        guard let id = sidebarSelection?.deviceID, id != .demo else { return nil }
        return broker.record(for: id)
    }

    var isDemoSelected: Bool { sidebarSelection?.deviceID == .demo }

    var detailContent: DetailContent {
        guard let selection = sidebarSelection else { return .welcome }
        if selection.deviceID == .demo { return .browser }
        guard let record = broker.record(for: selection.deviceID) else { return .welcome }
        return record.state.isMTPReady ? .browser : .deviceState(record)
    }

    var selectedDeviceName: String? {
        if isDemoSelected { return localization.t("demo.deviceName") }
        return selectedRecord?.displayName
    }

    // MARK: - Actions

    func refresh() {
        if let id = sidebarSelection?.deviceID, id != .demo {
            broker.refreshStorages(id)
        }
        Task { await browser.reload() }
    }

    // MARK: - Safely disconnect

    /// Active transfers that involve a device.
    func activeTransferCount(for id: DeviceID) -> Int {
        transfers.activeJobs.filter { $0.deviceID == id }.count
    }

    /// "안전하게 연결 해제": asks first when transfers are running.
    func requestSafeDisconnect(_ id: DeviceID) {
        guard id != .demo, broker.record(for: id)?.state.isUSBPresent == true else { return }
        let running = activeTransferCount(for: id)
        if running > 0 {
            activeDialog = .confirmDisconnect(id, running)
        } else {
            Task { await safelyDisconnect(id) }
        }
    }

    /// Cancels the device's transfers, unmounts it from Finder, settles
    /// delayed deletes and closes the MTP session, so the cable can be pulled.
    func safelyDisconnect(_ id: DeviceID) async {
        let name = broker.record(for: id)?.displayName ?? id.rawValue
        for job in transfers.activeJobs where job.deviceID == id {
            transfers.cancel(job)
        }
        while activeTransferCount(for: id) > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard await finder.unmountVolumes(of: id) else {
            post(.disconnectBlocked)
            return
        }
        await finder.repository.writes.finishAllPendingDeletes(deviceID: id)
        await broker.safelyDisconnect(id)
        finder.scheduleRefresh()
        post(.safelyDisconnected(name))
    }

    /// File › Open (⌘O): folders open, files get Quick Look.
    func openSelection() {
        guard let item = browser.selectedItem else { return }
        if item.isFolder {
            Task { await browser.enter(item) }
        } else if canPreview(item) {
            Task { await previewSelection() }
        }
    }

    /// The Finder volume of the storage selected in the sidebar.
    var selectedFinderVolume: MTPFileRepository.Volume? {
        guard case .storage(let deviceID, let storageID) = sidebarSelection else { return nil }
        return finder.volumes.first { $0.address.deviceID == deviceID.rawValue && $0.address.storageID == storageID }
    }

    func showSelectedVolumeInFinder() {
        guard let volume = selectedFinderVolume, let url = finder.state(of: volume).mountURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func completeOnboarding() {
        settings.onboardingCompleted = true
        showOnboarding = false
    }

    func setDemoDeviceVisible(_ visible: Bool) {
        settings.showDemoDevice = visible
        finder.scheduleRefresh()
        if !visible, isDemoSelected { sidebarSelection = nil }
    }

    func setFoldersFirst(_ value: Bool) {
        settings.foldersFirst = value
        browser.sort.foldersFirst = value
        local.sort.foldersFirst = value
    }

    // MARK: - Broker → UI

    private func handle(_ change: DeviceChange) {
        if let record = change.record {
            if record.state == .connected, change.previousState != .connected {
                post(.deviceConnected(record.displayName))
                // A new session: clean what an interrupted earlier one left.
                if let fileSystem = broker.fileSystem(for: record.id) {
                    Task { [journal] in await journal.sweep(fileSystem) }
                }
                // First usable device: open it, unless the user is browsing a real device.
                if sidebarSelection == nil || isDemoSelected {
                    sidebarSelection = .storage(record.id, record.storages.first?.id ?? 0)
                }
            } else if case .failed = record.state, !Self.isFailure(change.previousState) {
                post(.connectionFailed(record.displayName))
            } else if record.state == .disconnected {
                post(.deviceDisconnected(record.displayName))
            }
        }
        if change.id == sidebarSelection?.deviceID {
            syncBrowser()
        }
        finder.scheduleRefresh()
    }

    /// Makes the browser reflect the selection and the device's current
    /// session. A new session generation always starts at the storage root:
    /// MTP object handles do not survive a reconnect.
    func syncBrowser() {
        guard let selection = sidebarSelection else {
            browser.reset()
            return
        }

        if selection.deviceID == .demo {
            let storage = demoStorages.first { $0.id == selection.storageID } ?? demoStorages.first
            guard let storage else { browser.reset(); return }
            if browser.fileSystem !== demoDevice || browser.storage?.id != storage.id {
                browser.setRoot(demoDevice, storage: storage)
                Task { await browser.reload() }
            }
            return
        }

        guard let record = broker.record(for: selection.deviceID) else {
            browser.reset()
            sidebarSelection = nil
            return
        }
        guard record.state.isMTPReady,
              let storage = record.storages.first(where: { $0.id == selection.storageID }) ?? record.storages.first else {
            browser.reset()
            return
        }
        if browser.deviceID == record.id, browser.generation == record.generation, browser.storage?.id == storage.id {
            return
        }
        guard let fileSystem = broker.fileSystem(for: record.id) else {
            browser.reset()
            return
        }
        browser.setRoot(fileSystem, storage: storage)
        Task { await browser.reload() }
    }

    private static func isFailure(_ state: ConnectionState?) -> Bool {
        if case .failed = state { return true }
        return false
    }

    func post(_ kind: AppNotice.Kind) {
        let notice = AppNotice(kind: kind)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.notice?.id == notice.id else { return }
            self?.notice = nil
        }
    }
}

/// USB monitor that reports nothing (unit-test host process).
final class InertUSBMonitor: USBDeviceMonitoring {
    let events = AsyncStream<USBEvent> { _ in }
    func start() {}
    func stop() {}
    func exclusiveOwner(registryID: UInt64) async -> String? { nil }
}

/// MTP backend that never opens anything (unit-test host process).
struct InertMTPBackend: MTPBackend {
    func preflight(_ target: MTPTarget) -> MTPPreflightResult { .failed(.disconnected) }
    func open(_ target: MTPTarget) throws(DeviceError) -> any MTPConnection { throw .disconnected }
}
