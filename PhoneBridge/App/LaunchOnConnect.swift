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

    static var launcherIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.phonebridge.PhoneBridge") + ".Launcher"
    }

    init(service: LoginItemService = SMAppService.loginItem(identifier: LaunchOnConnectSetting.launcherIdentifier),
         openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.service = service
        self.openSettings = openSettings
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
            } else {
                try service.unregister()
            }
            refresh()
            Log.app.info("open on connect: \(enabled ? "on" : "off", privacy: .public), status \(String(describing: self.state), privacy: .public)")
        } catch {
            let nsError = error as NSError
            Log.app.error("open on connect \(enabled ? "register" : "unregister", privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code)")
            if enabled {
                state = .unavailable("\(nsError.domain) \(nsError.code)")
            } else {
                refresh()
            }
        }
    }

    func openLoginItemsSettings() {
        openSettings()
    }
}
