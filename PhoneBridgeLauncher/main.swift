import AppKit
import OSLog

// PhoneBridge Launcher (D73): a background-only login item, registered from
// Settings › General › "휴대전화를 연결하면 PhoneBridge 열기". It only watches
// USB device arrival (IORegistry, no device I/O) and opens PhoneBridge when a
// phone or tablet (Android, iPhone, iPad) is plugged in. It never talks to the phone.

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.phonebridge.PhoneBridge.Launcher", category: "launcher")

/// PhoneBridge.app/Contents/Library/LoginItems/PhoneBridgeLauncher.app → PhoneBridge.app
func hostApp() -> URL? {
    let url = Bundle.main.bundleURL
        .deletingLastPathComponent()  // LoginItems
        .deletingLastPathComponent()  // Library
        .deletingLastPathComponent()  // Contents
        .deletingLastPathComponent()  // PhoneBridge.app
    let launcherID = Bundle.main.bundleIdentifier ?? ""
    let expected = launcherID.hasSuffix(".Launcher") ? String(launcherID.dropLast(".Launcher".count)) : nil
    guard let expected, Bundle(url: url)?.bundleIdentifier == expected else { return nil }
    return url
}

@MainActor
func openPhoneBridge() {
    guard let app = hostApp() else {
        log.error("PhoneBridge.app not found next to the launcher; not opening")
        return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
        if let error {
            log.error("could not open PhoneBridge: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        } else {
            log.info("opened PhoneBridge for a connected phone")
        }
    }
}

let monitor = IOKitUSBMonitor()
Task { @MainActor in
    var detector = PhoneAttachDetector()
    for await event in monitor.events {
        if detector.handle(event) { openPhoneBridge() }
    }
}
monitor.start()
log.info("watching for phones")
// Diagnostics (launch argument only): run the "open PhoneBridge" step once.
if UserDefaults.standard.bool(forKey: "diagnostics.openNow") {
    Task { @MainActor in openPhoneBridge() }
}
dispatchMain()
