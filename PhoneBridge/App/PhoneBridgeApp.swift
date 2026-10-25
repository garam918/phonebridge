import AppKit
import SwiftUI

@main
struct PhoneBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppLaunchContext.isRunningUnitTests ? AppModel.inert() : AppModel.live()
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        Window("PhoneBridge", id: "main") {
            ContentView()
                .appEnvironment(model)
                .modifier(WindowSnapshotsTrigger(model: model))
                .task {
                    await model.start(startBroker: !AppLaunchContext.isRunningUnitTests)
                }
        }
        .defaultSize(width: 1080, height: 680)
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
                .appEnvironment(model)
        }
    }
}

enum AppLaunchContext {
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

extension View {
    /// Injects the composition root's services into the SwiftUI environment.
    func appEnvironment(_ model: AppModel) -> some View {
        environment(model)
            .environment(model.localization)
            .environment(model.settings)
            .environment(\.locale, model.localization.locale)
    }
}

/// Closes MTP sessions before the process exits so the device is left in a
/// clean state (no dangling session for the next MTP client).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    static let shutdownTimeout: Duration = .seconds(5)
    /// The part of `shutdownTimeout` that stopping transfers may take; the
    /// Finder volume and MTP session cleanup always runs after it.
    static let transferStopTimeout: Duration = .seconds(2)

    /// Closing the window while transfers run does not quit: they go on, and
    /// the Dock icon brings the window back (audit 2026-10-23, M3).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Self.model?.transfers.activeJobs.isEmpty ?? true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, !AppLaunchContext.isRunningUnitTests else { return .terminateNow }
        guard Self.shouldQuit(activeTransfers: model.transfers.activeJobs.count,
                              confirm: { Self.confirmQuit(cancelling: $0, localization: model.localization) }) else {
            return .terminateCancel
        }
        // Quit always completes: after `shutdownTimeout` the app replies even if
        // a step (an unplugged device, a stuck unmount) has not finished.
        var replied = false
        let reply: @MainActor (Bool) -> Void = { timedOut in
            guard !replied else { return }
            replied = true
            if timedOut { Log.app.error("shutdown did not finish in time; quitting anyway") }
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await Self.shutdownSequence(for: model).run()
            reply(false)
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.shutdownTimeout)
            reply(true)
        }
        return .terminateLater
    }

    /// Quitting cancels running transfers, so the user is asked first.
    @MainActor
    static func shouldQuit(activeTransfers: Int, confirm: (Int) -> Bool) -> Bool {
        activeTransfers == 0 || confirm(activeTransfers)
    }

    @MainActor
    private static func confirmQuit(cancelling count: Int, localization loc: LocalizationManager) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc.t("quit.confirm.title", count)
        alert.informativeText = loc.t("quit.confirm.message")
        alert.addButton(withTitle: loc.t("quit.confirm.keep"))
        alert.addButton(withTitle: loc.t("quit.confirm.quit"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    @MainActor
    static func shutdownSequence(for model: AppModel) -> ShutdownSequence {
        ShutdownSequence(
            stopTransfers: {
                // Cancelling removes staging files.
                model.transfers.cancelAll()
                model.previews.cancel()
                await model.transfers.waitUntilIdle()
            },
            cleanup: [
                { await model.finder.shutdown() },
                { await model.broker.shutdown() },
                { model.previews.purgeCache() },
            ],
            transferBudget: transferStopTimeout)
    }
}

/// The quit steps, apart from AppKit. A transfer stuck in a device call
/// (a cable pulled mid-transaction) gets `transferBudget`; the Finder volumes
/// are unmounted and the MTP sessions closed in any case (audit 2026-10-23, M2).
@MainActor
struct ShutdownSequence {
    var stopTransfers: @MainActor () async -> Void
    var cleanup: [@MainActor () async -> Void]
    var transferBudget: Duration

    func run() async {
        if await !Self.waitAtMost(transferBudget, stopTransfers) {
            Log.app.error("transfers did not stop in time; closing sessions anyway")
        }
        for step in cleanup { await step() }
    }

    /// Runs `body`, returning true when it finished within `limit` and false
    /// when the limit came first (`body` keeps running).
    static func waitAtMost(_ limit: Duration, _ body: @escaping @MainActor () async -> Void) async -> Bool {
        final class Once {
            var continuation: CheckedContinuation<Bool, Never>?
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { @MainActor in
                await body()
                once.continuation?.resume(returning: true)
                once.continuation = nil
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.continuation?.resume(returning: false)
                once.continuation = nil
            }
        }
    }
}

/// Starts `WindowSnapshots` (diagnostics launch argument) once the app is up.
private struct WindowSnapshotsTrigger: ViewModifier {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            guard WindowSnapshots.isRequested else { return }
            try? await Task.sleep(for: .seconds(2))
            await WindowSnapshots.run(model: model, openSettings: { openSettings() })
        }
    }
}
