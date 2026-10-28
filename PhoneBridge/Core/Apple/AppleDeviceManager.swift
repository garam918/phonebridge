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

    /// `enabled` false (tests): never starts Image Capture.
    init(enabled: Bool = false, storageName: @escaping () -> String = { "Photos & Videos" }) {
        self.enabled = enabled
        self.storageName = storageName
    }

    /// Whether an iPhone/iPad is on USB (set by `AppModel` from the USB monitor).
    private(set) var wantsBrowsing = false
    @ObservationIgnored private var pendingStop: Task<Void, Never>?
    /// An iPhone briefly leaves the bus when it is trusted or restarts its USB
    /// stack; browsing stops only once it has stayed away this long.
    @ObservationIgnored var stopDelay: Duration = .seconds(3)

    /// Image Capture runs only while an iPhone or iPad is connected. A running
    /// device browser makes macOS's ptpcamerad open every PTP-class device,
    /// Android phones in File transfer mode included, and libmtp then finds
    /// them taken ("ptpcamerad" busy, 2026-10-28, D78).
    func setBrowsing(_ wanted: Bool) {
        guard wanted != wantsBrowsing else { return }
        wantsBrowsing = wanted
        pendingStop?.cancel()
        pendingStop = nil
        if wanted {
            start()
        } else if browser != nil {
            pendingStop = Task { [weak self, stopDelay] in
                try? await Task.sleep(for: stopDelay)
                guard !Task.isCancelled, let self, !self.wantsBrowsing else { return }
                self.stop()
            }
        }
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

    private func becameReady(_ camera: ICCameraDevice) {
        guard let id = id(of: camera) else { return }
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
            Log.app.error("iPhone/iPad session failed: \(nsError.domain, privacy: .public) \(nsError.code)")
            update(id) { $0.state = .failed("\(nsError.domain) \(nsError.code)") }
            return
        }
        let restricted = (device as? ICCameraDevice)?.isAccessRestrictedAppleDevice ?? false
        update(id) { $0.state = restricted ? .needsTrust : .loading(nil) }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}

    func didRemove(_ device: ICDevice) {
        remove(device)
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard let id = id(of: device) else { return }
        fileSystems[id] = nil
        update(id) { $0.state = .needsTrust }
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard let id = id(of: device) else { return }
        update(id) { $0.state = .loading(nil) }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
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
