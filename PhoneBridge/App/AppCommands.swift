import SwiftUI

/// Menu bar items owned by PhoneBridge. Titles go through LocalizationManager
/// so they follow a runtime language switch; AppKit's standard menus follow
/// the system language until next launch.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        let loc = model.localization
        let browser = model.browser

        CommandGroup(replacing: .newItem) {
            Button(loc.t("action.open")) { model.openSelection() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(browser.selectedItem == nil)
            Button(loc.t("action.getInfo")) { model.showInspector = true }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model.detailContent != .browser)
            Button(loc.t("search.prompt")) { model.searchFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.detailContent != .browser)
            Divider()
            Button(loc.t("action.newFolderEllipsis")) { model.activeDialog = .newFolder }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.canWriteHere)
            Button(loc.t("action.uploadEllipsis")) { FileActions.upload(model: model, loc: loc) }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!model.canWriteHere)
            Button(loc.t("action.downloadToDefault", model.localAccess.defaultFolder.lastPathComponent)) {
                FileActions.download(browser.selectedItems, model: model, loc: loc, choosingDestination: false)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!model.hasDeviceSelection)
            Button(loc.t("action.downloadTo")) {
                FileActions.download(browser.selectedItems, model: model, loc: loc, choosingDestination: true)
            }
            .keyboardShortcut("d", modifiers: [.command, .option, .shift])
            .disabled(!model.hasDeviceSelection)
            Divider()
            Button(loc.t("action.preview")) { Task { await model.previewSelection() } }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!model.canPreview(browser.selectedItem))
            Button(loc.t("action.renameEllipsis")) {
                if let item = browser.selectedItem { model.activeDialog = .rename(item) }
            }
            .disabled(!model.canRenameHere || browser.selectedItem == nil)
            Button(loc.t("action.deleteEllipsis")) { model.requestDelete(browser.selectedItems) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.hasDeviceSelection || !model.canDeleteHere)
        }

        CommandGroup(after: .toolbar) {
            Button(loc.t("menu.view.asList")) { model.settings.viewMode = .list }
                .keyboardShortcut("1", modifiers: .command)
            Button(loc.t("menu.view.asGrid")) { model.settings.viewMode = .grid }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button(model.showInspector ? loc.t("menu.view.hideInspector") : loc.t("menu.view.showInspector")) {
                model.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Button(model.settings.dualPane ? loc.t("menu.view.hideMacPane") : loc.t("menu.view.showMacPane")) {
                model.toggleDualPane()
            }
            .keyboardShortcut("2", modifiers: [.command, .option])
            Button(model.isTransferPanelExpanded ? loc.t("transfer.hideQueue") : loc.t("transfer.showQueue")) {
                model.isTransferPanelExpanded.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu(loc.t("menu.device")) {
            let record = model.selectedRecord
            Button(loc.t("action.safelyDisconnect")) {
                if let record { model.requestSafeDisconnect(record.id) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(record.map { !$0.state.isUSBPresent || $0.state == .safelyDisconnected } ?? true)
            Button(loc.t(record?.state == .safelyDisconnected ? "action.reconnect" : "action.retry")) {
                if let record { model.broker.retry(record.id) }
            }
            .disabled(!(record?.state.canRetry ?? false))
            if model.finder.isAvailable {
                Divider()
            }
            if !model.finder.isAvailable {
                EmptyView()
            } else if let volume = model.selectedFinderVolume {
                if model.finder.state(of: volume).mountURL != nil {
                    Button(loc.t("finder.showInFinder")) { model.showSelectedVolumeInFinder() }
                    Button(loc.t("finder.unmount")) { Task { await model.finder.unmount(volume) } }
                } else {
                    Button(loc.t("finder.mountInFinder")) { Task { await model.finder.mount(volume) } }
                        .disabled(!model.settings.finderIntegrationEnabled || !model.finder.mounter.canMountProgrammatically)
                }
            } else {
                Button(loc.t("finder.mountInFinder")) {}.disabled(true)
            }
        }

        CommandGroup(replacing: .help) {
            Button(loc.t("menu.help.gettingStarted")) { model.showOnboarding = true }
            Button(loc.t("menu.help.troubleshooting")) { model.showTroubleshooting = true }
            Divider()
            Button(loc.t("menu.help.checkForUpdates", AppLinks.currentVersion)) { NSWorkspace.shared.open(AppLinks.releases) }
            Divider()
            Button(loc.t("menu.help.exportDiagnostics")) { DiagnosticsReport.export(model: model) }
            Button(loc.t("menu.help.licenses")) {
                if let notice = Bundle.main.url(forResource: "NOTICE", withExtension: "txt") {
                    NSWorkspace.shared.open(notice)
                }
            }
        }

        CommandMenu(loc.t("menu.go")) {
            Button(loc.t("menu.go.back")) { Task { await browser.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!browser.canGoBack)
            Button(loc.t("menu.go.forward")) { Task { await browser.goForward() } }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!browser.canGoForward)
            Button(loc.t("menu.go.enclosingFolder")) { Task { await browser.goUp() } }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!browser.canGoUp)
            Divider()
            Button(loc.t("menu.go.refresh")) { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(browser.fileSystem == nil)
        }
    }
}

/// Where "Check for Updates…" sends the user. The app has no network
/// entitlement and makes no request itself: the default browser opens the
/// releases page, and the user compares it with the version in the menu title
/// (D84). Homebrew users get new versions with `brew upgrade`.
enum AppLinks {
    static let releases = URL(string: "https://github.com/garam918/phonebridge/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
