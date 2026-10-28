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

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: defaultsKey) || isPromo }
    /// `-diagnostics.windowSnapshots promo`: two main-window scenes for
    /// announcements, drawn from the virtual device's sample data without its
    /// test labels. Never shown to users: the argument is the only way in.
    static var isPromo: Bool { UserDefaults.standard.string(forKey: defaultsKey) == "promo" }

    static func run(model: AppModel, openSettings: () -> Void) async {
        if isPromo {
            await runPromo(model: model)
            return
        }
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

    private static func runPromo(model: AppModel) async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PhoneBridgePromo", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "PhoneBridgeSnapshotMac", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for folder in ["사진 백업", "업무 자료"] {
            try? FileManager.default.createDirectory(at: scratch.appending(path: folder), withIntermediateDirectories: true)
        }
        for (name, bytes) in [("견적서.xlsx", 48_000), ("발표 자료.pdf", 2_400_000), ("메모.txt", 2_000)] {
            try? Data(count: bytes).write(to: scratch.appending(path: name))
        }
        LocalizationManager.promoOverrides = [
            "sidebar.demoDevices": "기기", "demo.deviceName": "Android 휴대전화", "demo.status": "연결됨",
        ]
        model.showOnboarding = false
        try? await Task.sleep(for: .seconds(3))
        model.localization.setLanguage(.korean)

        let looks: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        resizeMainWindow(to: CGSize(width: 1280, height: 800))
        model.showInspector = false
        model.isTransferPanelExpanded = false

        // 1. Android | Mac side by side, list view, in Download.
        model.settings.viewMode = .list
        if !model.settings.dualPane { model.toggleDualPane() }
        await model.local.open(root: scratch)
        for (appearance, look) in looks {
            NSApp.appearance = NSAppearance(named: appearance)
            await openDemoFolder(["Download"], model: model)
            await capture("promo-1-dual-\(look)", to: directory, model: model, scratch: scratch)
        }

        // 2. Photos with a finished download to the Mac in the transfer list.
        model.toggleDualPane()
        model.isTransferPanelExpanded = true
        for (appearance, look) in looks {
            NSApp.appearance = NSAppearance(named: appearance)
            await openDemoFolder(["DCIM", "Camera"], model: model)
            let items = model.browser.displayedItems
            if let video = items.first(where: { $0.name.hasPrefix("VID_") }), let fs = model.browser.fileSystem {
                let job = model.transfers.enqueue(.download(items: [model.browser.reference(for: video)], generation: fs.generation,
                                                            destination: scratch.appending(path: "사진 백업"), deleteSourceAfter: false),
                                                  destinationName: "사진 백업")
                for _ in 0..<50 where !job.state.isFinished { try? await Task.sleep(for: .milliseconds(100)) }
            }
            if let photo = items.first(where: { $0.name.hasSuffix("05.jpg") }) { model.browser.selection = [photo.id] }
            try? await Task.sleep(for: .seconds(1))
            await capture("promo-2-photos-\(look)", to: directory, model: model, scratch: scratch)
            model.transfers.clearFinished()
            try? FileManager.default.removeItem(at: scratch.appending(path: "사진 백업/VID_20260915_183012.mp4"))
        }
        try? FileManager.default.removeItem(at: scratch)
        NSApp.appearance = nil
        LocalizationManager.promoOverrides = [:]
        Log.app.info("promo snapshots written to \(directory.path, privacy: .private)")
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private static func openDemoFolder(_ path: [String], model: AppModel) async {
        model.sidebarSelection = nil
        try? await Task.sleep(for: .milliseconds(300))
        if let storage = model.demoStorages.first { model.sidebarSelection = .storage(.demo, storage.id) }
        try? await Task.sleep(for: .milliseconds(800))
        for name in path {
            guard let folder = model.browser.displayedItems.first(where: { $0.isFolder && $0.name == name }) else { return }
            await model.browser.enter(folder)
            try? await Task.sleep(for: .milliseconds(500))
        }
        model.browser.selection = []
    }

    private static func resizeMainWindow(to size: CGSize) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.sheetParent == nil }) else { return }
        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: true)
    }

    /// The window at 2x, with the sidebar drawn in: its glass container is
    /// skipped by `cacheDisplay`, so the sidebar's own content is rendered
    /// separately onto a plain panel in the sidebar's place.
    private static func promoImage(of view: NSView, model: AppModel) async -> Data? {
        func render(_ v: NSView) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = v.bounds.size
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep
        }
        func descendants(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(descendants) }
        guard let main = render(view) else { return nil }
        let all = descendants(view)
        let glass = all.first { String(describing: type(of: $0)) == "NSGlassEffectView" }
        let sidebarContent = glass.flatMap { g in descendants(g).first { String(describing: type(of: $0)).hasPrefix("NSHostingView") } }
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // The same sidebar, drawn again in a plain off-screen window (no glass),
        // below the title bar area. Done before drawing starts: it awaits.
        var sideImage: NSBitmapImageRep?
        var sideRect = NSRect.zero
        let selectedRows = sidebarContent.map { descendants($0).compactMap { $0 as? NSTableRowView }.filter(\.isSelected)
            .map { $0.convert($0.bounds, to: nil) } } ?? []
        if let sidebarContent {
            let full = sidebarContent.convert(sidebarContent.bounds, to: nil)
            sideRect = NSRect(x: full.minX, y: full.minY, width: full.width, height: full.height - 52)
            let host = NSHostingView(rootView: SidebarView().appEnvironment(model).frame(width: sideRect.width, height: sideRect.height))
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: sideRect.width, height: sideRect.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = view.effectiveAppearance
            window.backgroundColor = .clear
            window.contentView = host
            window.orderBack(nil)
            // Its selection would draw as a solid block off screen; the highlight
            // is painted from the real sidebar's selected row instead.
            let selection = model.sidebarSelection
            model.sidebarSelection = nil
            try? await Task.sleep(for: .milliseconds(800))
            host.layoutSubtreeIfNeeded()
            sideImage = render(host)
            window.orderOut(nil)
            model.sidebarSelection = selection
        }

        let size = view.bounds.size
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
        NSRect(origin: .zero, size: size).fill()
        if let glass {
            let frame = glass.convert(glass.bounds, to: nil).insetBy(dx: 8, dy: 8)
            (dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.945, alpha: 1)).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 16, yRadius: 16).fill()
        }
        main.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let sidebarContent {
            // The selected row's highlight is a visual-effect view too.
            for frame in selectedRows {
                let r = frame.insetBy(dx: 10, dy: 0)
                (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            }
            if let side = sideImage {
                side.draw(in: sideRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])
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
            if isPromo, window.sheetParent == nil, index == 0, let promo = await promoImage(of: view, model: model) {
                try? promo.write(to: directory.appending(path: "\(name)@2x.png"))
            }
        }
    }
}
