import AppKit
import SwiftUI

/// Diagnostics (launch argument `-diagnostics.windowSnapshots YES`): walks the
/// real windows through both languages, light/dark and two window sizes and
/// saves what the app itself draws — no screen-recording permission needed.
/// Output: the app container's tmp/PhoneBridgeWindows. The Mac pane shows an
/// empty scratch folder so no personal file names end up in the images.
@MainActor
enum WindowSnapshots {
    static let defaultsKey = "diagnostics.windowSnapshots"

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    static func run(model: AppModel, openSettings: () -> Void) async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PhoneBridgeWindows", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "PhoneBridgeSnapshotMac", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try? Data("예시".utf8).write(to: scratch.appending(path: "예시 문서.txt"))
        model.showOnboarding = false
        // Wait for start-up (it may open the Mac pane on ~/Downloads) to finish.
        try? await Task.sleep(for: .seconds(3))

        for language in AppLanguage.allCases {
            model.localization.setLanguage(language)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                let look = appearance == .aqua ? "light" : "dark"
                for size in [CGSize(width: 900, height: 560), CGSize(width: 1280, height: 800)] {
                    let tag = "\(language.rawValue)-\(look)-\(Int(size.width))"
                    resizeMainWindow(to: size)

                    // Device browser: list, Mac pane, inspector, transfer queue open.
                    model.settings.viewMode = .list
                    if !model.settings.dualPane { model.toggleDualPane() }
                    await model.local.open(root: scratch)
                    model.showInspector = true
                    model.isTransferPanelExpanded = true
                    if let storage = model.demoStorages.first { model.sidebarSelection = .storage(.demo, storage.id) }
                    await capture("browser-list-\(tag)", to: directory, model: model, scratch: scratch)

                    // Icons, single pane.
                    model.settings.viewMode = .grid
                    model.toggleDualPane()
                    model.isTransferPanelExpanded = false
                    model.showInspector = false
                    await capture("browser-grid-\(tag)", to: directory, model: model, scratch: scratch)

                    // No device selected: welcome and troubleshooting.
                    model.sidebarSelection = nil
                    await capture("welcome-\(tag)", to: directory, model: model, scratch: scratch)
                }
                // Sheets and Settings at the default size.
                resizeMainWindow(to: CGSize(width: 1080, height: 680))
                model.showOnboarding = true
                await capture("onboarding-\(language.rawValue)-\(look)", to: directory, model: model, scratch: scratch)
                model.showOnboarding = false
                openSettings()
                await capture("settings-\(language.rawValue)-\(look)", to: directory, model: model, scratch: scratch)
                NSApp.windows.filter { $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("Settings") || $0.title.contains("설정") }
                    .forEach { $0.close() }
            }
        }
        NSApp.appearance = nil
        Log.app.info("window snapshots written to \(directory.path, privacy: .private)")
        // Not from inside this main-actor task: the quit handler needs the main
        // actor, which would stay busy for the whole nested quit run loop.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private static func resizeMainWindow(to size: CGSize) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.sheetParent == nil }) else { return }
        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: true)
    }

    /// Every visible window (main window, sheet, Settings) as its own PNG.
    /// Never captures while the Mac pane shows a real folder.
    private static func capture(_ name: String, to directory: URL, model: AppModel, scratch: URL) async {
        if model.local.currentURL?.standardizedFileURL != scratch.standardizedFileURL {
            await model.local.open(root: scratch)
        }
        try? await Task.sleep(for: .milliseconds(900))
        guard model.local.currentURL?.standardizedFileURL == scratch.standardizedFileURL else {
            Log.app.error("snapshot \(name, privacy: .public) skipped: Mac pane not on the scratch folder")
            return
        }
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            let suffix = window.sheetParent != nil ? "-sheet" : (index == 0 ? "" : "-w\(index)")
            try? png.write(to: directory.appending(path: "\(name)\(suffix).png"))
        }
    }
}
