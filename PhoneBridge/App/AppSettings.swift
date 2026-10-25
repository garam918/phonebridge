import Foundation
import Observation

enum BrowserViewMode: String, CaseIterable, Sendable {
    case list, grid
}

/// Non-language preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let showDemoDevice = "settings.showDemoDevice"
        static let viewMode = "settings.viewMode"
        static let foldersFirst = "settings.foldersFirst"
        static let dualPane = "settings.dualPane"
        static let finderIntegration = "settings.finderIntegration"
        static let finderAutoMount = "settings.finderAutoMount"
        /// "Finder에서 쓰기 허용(실험적)"; off by default (사용자 결정).
        static let finderWrites = "settings.finderWrites"
        static let onboardingCompleted = "settings.onboardingCompleted"
        static let dualPaneFraction = "settings.dualPaneFraction"
        /// Finder writes also reach real devices (Settings › Finder, off by default).
        static let finderWritesRealDevices = "settings.finderWritesRealDevices"
        /// Diagnostics (launch argument only): same as above for one launch (W5).
        static let diagnosticsRealDeviceWrites = "diagnostics.finderWritesRealDevices"
        /// Diagnostics (launch argument only): demo device upload speed in MB/s,
        /// to see Finder wait for a long upload.
        static let demoUploadRate = "diagnostics.demoUploadMBps"
        /// Diagnostics (launch argument only, W5): real-device writes only in this root folder.
        static let finderWriteScope = "diagnostics.finderWriteScope"
        /// Diagnostics (launch argument only, W5): list hidden staging/backup objects.
        static let showStagingObjects = "diagnostics.showStagingObjects"
        /// Diagnostics (launch argument only): auto-mount the virtual device in
        /// Finder too, so the mount can be checked without clicking.
        static let autoMountDemo = "diagnostics.autoMountDemo"
    }

    var showDemoDevice: Bool {
        didSet { defaults.set(showDemoDevice, forKey: Key.showDemoDevice) }
    }

    var viewMode: BrowserViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: Key.viewMode) }
    }

    var foldersFirst: Bool {
        didSet { defaults.set(foldersFirst, forKey: Key.foldersFirst) }
    }

    /// Android | Mac two-pane mode (off by default: Android browser only).
    var dualPane: Bool {
        didSet { defaults.set(dualPane, forKey: Key.dualPane) }
    }

    /// Serve Finder (FSKit) volumes. Off by default: needs the extension enabled.
    var finderIntegrationEnabled: Bool {
        didSet { defaults.set(finderIntegrationEnabled, forKey: Key.finderIntegration) }
    }

    /// Mount every storage of a device in Finder as soon as it connects.
    /// Share of the Android pane in Android | Mac (0.15–0.85).
    var dualPaneFraction: Double {
        didSet { defaults.set(dualPaneFraction, forKey: Key.dualPaneFraction) }
    }

    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    var finderWritesEnabled: Bool {
        didSet { defaults.set(finderWritesEnabled, forKey: Key.finderWrites) }
    }

    /// Writes from Finder reach real devices too, not only the virtual device.
    /// Applies only while `finderWritesEnabled` is on.
    var finderWritesRealDevices: Bool {
        didSet { defaults.set(finderWritesRealDevices, forKey: Key.finderWritesRealDevices) }
    }

    /// Diagnostics launch arguments: not shown in the UI, never persisted by the app.
    let demoUploadRate: Double
    let finderWriteScope: String?
    let showStagingObjects: Bool
    let autoMountDemo: Bool

    var finderAutoMount: Bool {
        didSet { defaults.set(finderAutoMount, forKey: Key.finderAutoMount) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Reads a Bool that may also arrive as "YES"/"1" (launch arguments).
    private static func bool(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showDemoDevice = Self.bool(defaults, Key.showDemoDevice, default: true)
        viewMode = defaults.string(forKey: Key.viewMode).flatMap(BrowserViewMode.init(rawValue:)) ?? .list
        foldersFirst = Self.bool(defaults, Key.foldersFirst, default: true)
        dualPane = Self.bool(defaults, Key.dualPane, default: false)
        finderIntegrationEnabled = Self.bool(defaults, Key.finderIntegration, default: false)
        finderAutoMount = Self.bool(defaults, Key.finderAutoMount, default: true)
        finderWritesRealDevices = Self.bool(defaults, Key.finderWritesRealDevices, default: false)
            || Self.bool(defaults, Key.diagnosticsRealDeviceWrites, default: false)
        demoUploadRate = defaults.double(forKey: Key.demoUploadRate)
        finderWriteScope = defaults.string(forKey: Key.finderWriteScope).flatMap { $0.isEmpty ? nil : $0 }
        showStagingObjects = Self.bool(defaults, Key.showStagingObjects, default: false)
        autoMountDemo = Self.bool(defaults, Key.autoMountDemo, default: false)
        finderWritesEnabled = Self.bool(defaults, Key.finderWrites, default: false)
        onboardingCompleted = Self.bool(defaults, Key.onboardingCompleted, default: false)
        let fraction = defaults.double(forKey: Key.dualPaneFraction)
        dualPaneFraction = (0.15...0.85).contains(fraction) ? fraction : 0.55
    }
}
