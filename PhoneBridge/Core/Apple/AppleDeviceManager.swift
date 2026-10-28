import Foundation
import ImageCaptureCore
import Observation

/// Where an iPhone/iPad connection stands (D75).
enum AppleDeviceState: Equatable, Sendable {
    case connecting
    /// Locked, or "Trust This Computer?" not answered yet.
    case needsTrust
    /// Reading the photo list (percent, when Image Capture reports it).
    case loading(Int?)
    case ready
    case failed(String)
}

struct AppleDeviceRecord: Identifiable, Equatable, Sendable {
    let id: DeviceID
    var name: String
    var isTablet: Bool
    var state: AppleDeviceState
    var generation: UInt64
}

/// Decides when a catalog is complete from Image Capture's progress (0–100).
/// After an unlock Image Capture catalogs the photos again but does not always
/// send `deviceDidBecomeReady` a second time (iPhone, iOS 26.6, 2026-10-28:
/// stuck at "reading the photo list" although ptpcamerad had finished). Right
/// after the unlock the progress can still read 100 from the empty locked
/// catalog, so 100 has to hold for `settle` before it counts.
struct CatalogProgressWatch {
    enum Decision: Equatable {
        case loading(Int?)
        case ready
    }

    var settle: Duration = .seconds(2)
    private var completeSince: ContinuousClock.Instant?

    init(settle: Duration = .seconds(2)) {
        self.settle = settle
    }

    mutating func sample(percent: Int, at now: ContinuousClock.Instant) -> Decision {
        guard percent >= 100 else {
            completeSince = nil
            return .loading(max(0, percent))
        }
        let since = completeSince ?? now
        completeSince = since
        return now - since >= settle ? .ready : .loading(nil)
    }
}

struct AppleDeviceChange: Sendable {
    let id: DeviceID
    /// nil: the device was unplugged.
    let record: AppleDeviceRecord?
    let previous: AppleDeviceRecord?
}

/// Finds iPhones and iPads over USB with Image Capture and serves their
/// photos and videos as `ImageCaptureFileSystem`s. Android devices stay with
/// `DeviceBroker`; other cameras are ignored.
@MainActor
@Observable
final class AppleDeviceManager: NSObject {
    static let appleVendorID: Int32 = 0x05AC

    private(set) var records: [AppleDeviceRecord] = []
    @ObservationIgnored var onChange: ((AppleDeviceChange) -> Void)?

    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private let storageName: () -> String
    @ObservationIgnored private var browser: ICDeviceBrowser?
    @ObservationIgnored private var cameras: [DeviceID: ICCameraDevice] = [:]
    @ObservationIgnored private var fileSystems: [DeviceID: ImageCaptureFileSystem] = [:]
    @ObservationIgnored private var nextGeneration = UInt64(Date().timeIntervalSince1970 * 1000)
    @ObservationIgnored private var catalogWatches: [DeviceID: Task<Void, Never>] = [:]
    @ObservationIgnored var catalogPollInterval: Duration = .milliseconds(500)

    /// `enabled` false (tests): never starts Image Capture.
    init(enabled: Bool = false, storageName: @escaping () -> String = { "Photos & Videos" }) {
        self.enabled = enabled
        self.storageName = storageName
    }

    /// Whether an iPhone/iPad is on USB (set by `AppModel` from the USB monitor).
    private(set) var wantsBrowsing = false

    /// Image Capture starts only once an iPhone or iPad is connected. A running
    /// device browser makes macOS's ptpcamerad open every PTP-class device,
    /// Android phones in File transfer mode included, and libmtp then finds
    /// them taken ("ptpcamerad" busy, 2026-10-28, D78).
    ///
    /// Once started it keeps running until the app quits (D83). Stopping did
    /// not stop Image Capture in this process: it still opened an iPhone
    /// plugged in again, but announced it to no browser, and neither a
    /// restarted nor a new `ICDeviceBrowser` reported it afterwards (iPhone,
    /// macOS 26, 2026-10-28) — the iPhone could not be used again until
    /// PhoneBridge was restarted.
    func setBrowsing(_ wanted: Bool) {
        guard wanted != wantsBrowsing else { return }
        wantsBrowsing = wanted
        if wanted { start() }
    }

    func start() {
        guard enabled, browser == nil else { return }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue
                                                         | ICDeviceLocationTypeMask.local.rawValue) ?? .camera
        browser.start()
        self.browser = browser
        Log.app.info("iPhone/iPad browsing started")
    }

    func stop() {
        guard let browser else { return }
        browser.stop()
        self.browser = nil
        for camera in cameras.values { camera.requestCloseSession() }
        cameras.removeAll()
        for watch in catalogWatches.values { watch.cancel() }
        catalogWatches.removeAll()
        for record in records { removeRecord(record.id) }
        Log.app.info("iPhone/iPad browsing stopped")
    }

    func record(for id: DeviceID) -> AppleDeviceRecord? {
        records.first { $0.id == id }
    }

    func fileSystem(for id: DeviceID) -> ImageCaptureFileSystem? {
        record(for: id)?.state == .ready ? fileSystems[id] : nil
    }

    /// Opens the session again (failed or stuck connection).
    func retry(_ id: DeviceID) {
        guard let camera = cameras[id] else { return }
        update(id) { $0.state = .connecting }
        if camera.hasOpenSession { camera.requestCloseSession() }
        camera.requestOpenSession()
    }

    // MARK: - Records

    static func isAppleMobile(_ device: ICDevice) -> Bool {
        guard device.transportType == ICDeviceTransport.transportTypeUSB.rawValue || device.transportType == nil else { return false }
        let kind = device.productKind ?? ""
        return device.usbVendorID == appleVendorID || kind.hasPrefix("iPhone") || kind.hasPrefix("iPad") || kind.hasPrefix("iPod")
    }

    static func identifier(of device: ICDevice) -> DeviceID {
        let key = device.serialNumberString ?? device.persistentIDString ?? device.uuidString ?? device.name ?? "unknown"
        return DeviceID("ios:" + key)
    }

    private func id(of device: ICDevice) -> DeviceID? {
        cameras.first { $0.value === device }?.key
    }

    private func update(_ id: DeviceID, _ change: (inout AppleDeviceRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        change(&record)
        let previous = records[index]
        guard record != previous else { return }
        records[index] = record
        Log.app.info("iPhone/iPad \(id, privacy: .private(mask: .hash)) → \(String(describing: record.state), privacy: .public)")
        onChange?(AppleDeviceChange(id: id, record: record, previous: previous))
    }

    /// Follows the catalog while the record is loading: shows the percentage
    /// and becomes ready when it is complete, even without `deviceDidBecomeReady`.
    private func watchCatalog(_ camera: ICCameraDevice) {
        guard let id = id(of: camera) else { return }
        catalogWatches[id]?.cancel()
        catalogWatches[id] = Task { [weak self, weak camera, catalogPollInterval] in
            var watch = CatalogProgressWatch()
            var lastPercent = -1
            while !Task.isCancelled {
                guard let self, let camera, case .loading = self.record(for: id)?.state else { return }
                guard !camera.isAccessRestrictedAppleDevice else { return }
                let percent = Int(camera.contentCatalogPercentCompleted)
                if percent != lastPercent {
                    lastPercent = percent
                    Log.app.info("iPhone/iPad \(id, privacy: .private(mask: .hash)) catalog \(percent)%, \(camera.mediaFiles?.count ?? 0) media files")
                }
                switch watch.sample(percent: percent, at: .now) {
                case .ready:
                    Log.app.info("iPhone/iPad \(id, privacy: .private(mask: .hash)) catalog complete without a ready message")
                    self.becameReady(camera)
                    return
                case .loading(let shown):
                    if let shown { self.update(id) { $0.state = .loading(shown) } }
                }
                try? await Task.sleep(for: catalogPollInterval)
            }
        }
    }

    private func becameReady(_ camera: ICCameraDevice) {
        guard let id = id(of: camera), record(for: id)?.state != .ready else { return }
        catalogWatches[id]?.cancel()
        catalogWatches[id] = nil
        nextGeneration += 1
        let generation = nextGeneration
        fileSystems[id] = ImageCaptureFileSystem(deviceID: id, generation: generation,
                                                 backend: ICCameraBackend(device: camera), storageName: storageName())
        update(id) {
            $0.generation = generation
            $0.state = .ready
        }
    }

    private func remove(_ device: ICDevice) {
        guard let id = id(of: device) else { return }
        cameras[id] = nil
        catalogWatches[id]?.cancel()
        catalogWatches[id] = nil
        removeRecord(id)
    }

    private func removeRecord(_ id: DeviceID) {
        fileSystems[id] = nil
        let previous = record(for: id)
        records.removeAll { $0.id == id }
        Log.app.info("iPhone/iPad \(id, privacy: .private(mask: .hash)) removed")
        onChange?(AppleDeviceChange(id: id, record: nil, previous: previous))
    }
}

// MARK: - Simulated devices (unit tests; Image Capture is never started)

extension AppleDeviceManager {
    func simulateAttach(_ id: DeviceID, name: String, isTablet: Bool = false) {
        guard record(for: id) == nil else { return }
        let record = AppleDeviceRecord(id: id, name: name, isTablet: isTablet, state: .connecting, generation: 0)
        records.append(record)
        onChange?(AppleDeviceChange(id: id, record: record, previous: nil))
    }

    func simulateState(_ id: DeviceID, _ state: AppleDeviceState) {
        update(id) { $0.state = state }
    }

    func simulateReady(_ id: DeviceID, backend: CameraBackend) {
        nextGeneration += 1
        let generation = nextGeneration
        fileSystems[id] = ImageCaptureFileSystem(deviceID: id, generation: generation, backend: backend, storageName: storageName())
        update(id) {
            $0.generation = generation
            $0.state = .ready
        }
    }

    func simulateRemove(_ id: DeviceID) {
        removeRecord(id)
    }
}

// Image Capture calls its delegates on the main thread.
extension AppleDeviceManager: @preconcurrency ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice, Self.isAppleMobile(device) else { return }
        let id = Self.identifier(of: device)
        guard cameras[id] == nil else { return }
        cameras[id] = camera
        let record = AppleDeviceRecord(id: id, name: device.name ?? (device.productKind ?? "iPhone"),
                                       isTablet: (device.productKind ?? "").hasPrefix("iPad"),
                                       state: .connecting, generation: 0)
        records.append(record)
        Log.app.info("iPhone/iPad \(id, privacy: .private(mask: .hash)) found (\(device.productKind ?? "?", privacy: .public))")
        onChange?(AppleDeviceChange(id: id, record: record, previous: nil))
        camera.delegate = self
        camera.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        remove(device)
    }
}

extension AppleDeviceManager: @preconcurrency ICCameraDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        guard let id = id(of: device) else { return }
        if let error {
            let nsError = error as NSError
            // A locked iPhone: the session stays usable and Image Capture
            // reports the unlock with `cameraDeviceDidRemoveAccessRestriction`.
            if nsError.domain == ICErrorDomain, nsError.code == ICReturn.Code.deviceIsPasscodeLocked.rawValue {
                Log.app.info("iPhone/iPad \(id, privacy: .private(mask: .hash)) is locked")
                update(id) { $0.state = .needsTrust }
                return
            }
            Log.app.error("iPhone/iPad session failed: \(nsError.domain, privacy: .public) \(nsError.code)")
            update(id) { $0.state = .failed("\(nsError.domain) \(nsError.code)") }
            return
        }
        let camera = device as? ICCameraDevice
        if camera?.isAccessRestrictedAppleDevice ?? false {
            update(id) { $0.state = .needsTrust }
        } else if let camera, record(for: id)?.state != .ready {
            update(id) { $0.state = .loading(nil) }
            watchCatalog(camera)
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}

    func didRemove(_ device: ICDevice) {
        remove(device)
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard let id = id(of: device) else { return }
        Log.app.info("iPhone/iPad \(id, privacy: .private(mask: .hash)) access restricted")
        catalogWatches[id]?.cancel()
        catalogWatches[id] = nil
        fileSystems[id] = nil
        update(id) { $0.state = .needsTrust }
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard let id = id(of: device) else { return }
        Log.app.info("iPhone/iPad \(id, privacy: .private(mask: .hash)) access restriction removed")
        guard record(for: id)?.state != .ready else { return }
        update(id) { $0.state = .loading(nil) }
        if let camera = device as? ICCameraDevice { watchCatalog(camera) }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Log.app.info("iPhone/iPad ready message (restricted: \(device.isAccessRestrictedAppleDevice), \(device.mediaFiles?.count ?? 0) media files)")
        if device.isAccessRestrictedAppleDevice {
            if let id = id(of: device) { update(id) { $0.state = .needsTrust } }
            return
        }
        becameReady(device)
    }

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
