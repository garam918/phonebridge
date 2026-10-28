import Foundation
import Observation
import ServiceManagement

/// The login item that opens PhoneBridge when a phone or tablet is plugged in
/// (D73). macOS keeps the on/off state (System Settings › General › Login Items
/// & Extensions); the app only registers or unregisters it, so there is no
/// UserDefaults copy that could disagree. Off until the user turns it on.
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
@Observable
final class LaunchOnConnectSetting {
    enum State: Equatable {
        case off
        case on
        /// Registered, but the user has to allow it in System Settings.
        case needsApproval
        /// The launcher could not be registered (e.g. an unsigned build).
        case unavailable(String)
    }

    private(set) var state: State = .off
    @ObservationIgnored private let service: LoginItemService
    @ObservationIgnored private let openSettings: () -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let build: String

    static var launcherIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.phonebridge.PhoneBridge") + ".Launcher"
    }
    /// The app build whose launcher is registered (D79).
    static let registeredBuildKey = "launchOnConnect.registeredBuild"

    init(service: LoginItemService = SMAppService.loginItem(identifier: LaunchOnConnectSetting.launcherIdentifier),
         openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() },
         defaults: UserDefaults = .standard,
         build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") {
        self.service = service
        self.openSettings = openSettings
        self.defaults = defaults
        self.build = build
    }

    /// Called at launch. After an update the running launcher is still the old
    /// copy (moved to the Trash by the installer) until the next login, and an
    /// item first registered by a differently signed build keeps that build's
    /// launch constraint and cannot start (K51). Registering again once per
    /// build replaces it with this bundle's launcher.
    func refreshRegistration() {
        guard service.status == .enabled, defaults.string(forKey: Self.registeredBuildKey) != build else {
            refresh()
            return
        }
        do {
            try service.unregister()
            try service.register()
            defaults.set(build, forKey: Self.registeredBuildKey)
            refresh()
            Log.app.info("open on connect: launcher registered again for this build")
        } catch {
            let nsError = error as NSError
            Log.app.error("open on connect: registering again failed: \(nsError.domain, privacy: .public) \(nsError.code)")
            registrationFailed(nsError)
        }
    }

    var isOn: Bool { state == .on || state == .needsApproval }

    func refresh() {
        switch service.status {
        case .enabled: state = .on
        case .requiresApproval: state = .needsApproval
        case .notRegistered, .notFound: if case .unavailable = state {} else { state = .off }
        @unknown default: state = .off
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
                defaults.set(build, forKey: Self.registeredBuildKey)
            } else {
                try service.unregister()
                defaults.removeObject(forKey: Self.registeredBuildKey)
            }
            refresh()
            Log.app.info("open on connect: \(enabled ? "on" : "off", privacy: .public), status \(String(describing: self.state), privacy: .public)")
        } catch {
            let nsError = error as NSError
            Log.app.error("open on connect \(enabled ? "register" : "unregister", privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code)")
            if enabled {
                registrationFailed(nsError)
            } else {
                refresh()
            }
        }
    }

    /// `register()` also throws when the user switched PhoneBridge off in
    /// System Settings › Login Items; that is "needs approval", not a failure.
    private func registrationFailed(_ error: NSError) {
        if service.status == .requiresApproval {
            state = .needsApproval
        } else if service.status == .enabled {
            state = .on
        } else {
            state = .unavailable("\(error.domain) \(error.code)")
        }
    }

    func openLoginItemsSettings() {
        openSettings()
    }
}
