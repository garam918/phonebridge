import Foundation

/// Decides when a USB event means "a phone or tablet was just plugged
/// in" (the login-item launcher then opens PhoneBridge, D73).
///
/// - Devices already present when watching starts are not "plugged in now"
///   (logging in, or turning the setting on, with a phone attached).
/// - A phone re-enumerates when its USB mode changes (charging only → file
///   transfer); a reappearance within `reattachWindow` is the same plug-in,
///   unless PhoneBridge is not running then (quit with ⌘Q/⌘W, then the cable
///   pulled and plugged back in quickly, 2026-10-28).
/// - Anything that is not a phone or tablet (cameras, keyboards,
///   drives) is ignored.
struct PhoneAttachDetector {
    var startupGrace: TimeInterval = 3
    var reattachWindow: TimeInterval = 20

    private let startedAt: Date
    /// registryID → logical key, for phones currently attached.
    private var present: [UInt64: String] = [:]
    /// Logical keys already handled while attached.
    private var handled: Set<String> = []
    private var lastDetach: [String: Date] = [:]

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    /// true when PhoneBridge should be opened for this event.
    /// `appIsRunning` is asked only for a reappearance within `reattachWindow`.
    mutating func handle(_ event: USBEvent, now: Date = Date(), appIsRunning: () -> Bool = { true }) -> Bool {
        switch event {
        case .attached(let snapshot):
            guard Self.isPhone(snapshot) else { return false }
            let key = snapshot.logicalKey
            present[snapshot.registryID] = key
            guard !handled.contains(key) else { return false }
            handled.insert(key)
            if now.timeIntervalSince(startedAt) < startupGrace { return false }
            if let detached = lastDetach[key], now.timeIntervalSince(detached) < reattachWindow {
                return !appIsRunning()
            }
            return true
        case .detached(let registryID):
            guard let key = present.removeValue(forKey: registryID) else { return false }
            if !present.values.contains(key) {
                handled.remove(key)
                lastDetach[key] = now
            }
            return false
        }
    }

    /// An Android device in any USB mode (file transfer, photos, charging
    /// only), or an iPhone/iPad (photos and videos, D75).
    static func isPhone(_ snapshot: USBDeviceSnapshot) -> Bool {
        switch USBDeviceClassifier.classify(snapshot) {
        case .mtpCandidate, .androidPTPMode, .androidWithoutMTP, .unsupported(.appleDevice): true
        case .pending, .unsupported, .ignored: false
        }
    }
}
