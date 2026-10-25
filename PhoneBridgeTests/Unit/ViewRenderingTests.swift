import AppKit
import SwiftUI
import Testing
@testable import PhoneBridge

/// Renders screens offscreen in both languages, light and dark, narrow and
/// wide. Asserts they produce an image and writes PNGs to the app container's
/// tmp directory for review:
/// ~/Library/Containers/com.phonebridge.PhoneBridge.dev/Data/tmp/PhoneBridgeRenders
///
/// ImageRenderer draws pure SwiftUI only; AppKit-backed views (Table, List,
/// toolbar) are checked with the real window instead (TEST_PLAN 5).
@MainActor
@Suite("View rendering (offscreen)")
struct ViewRenderingTests {
    enum Look: String, CaseIterable { case light, dark }

    private static let outputDirectory = FileManager.default.temporaryDirectory
        .appending(path: "PhoneBridgeRenders", directoryHint: .isDirectory)

    private func model(language: AppLanguage) -> AppModel {
        let defaults = freshDefaults()
        defaults.set(false, forKey: AppSettings.Key.showDemoDevice)
        let localization = LocalizationManager(defaults: defaults)
        localization.setLanguage(language)
        let broker = DeviceBroker(monitor: MockUSBMonitor(), backend: MockMTPBackend())
        return AppModel(broker: broker, localization: localization, settings: AppSettings(defaults: defaults),
                        localAccess: LocalAccessManager(defaults: defaults, defaultFolder: FileManager.default.temporaryDirectory))
    }

    private func record(_ state: ConnectionState) -> DeviceRecord {
        DeviceRecord(id: USBDeviceSnapshot.fixture().logicalID,
                     usb: .fixture(interfaces: [.androidADB]), state: state, info: nil, storages: [], generation: 1)
    }

    /// Renders `view` for every language × look, at `widths`.
    private func renderMatrix(_ name: String, widths: [CGFloat] = [460, 640],
                              _ view: @escaping (AppModel) -> some View) throws {
        for language in AppLanguage.allCases {
            let model = model(language: language)
            for look in Look.allCases {
                for width in widths {
                    try render(view(model), model: model, name: "\(name)-\(language.rawValue)-\(look.rawValue)-\(Int(width))",
                               look: look, width: width)
                }
            }
        }
    }

    private func render(_ view: some View, model: AppModel, name: String, look: Look = .light, width: CGFloat = 560) throws {
        let appearance = NSAppearance(named: look == .dark ? .darkAqua : .aqua)!
        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let content = view
                .appEnvironment(model)
                .environment(\.colorScheme, look == .dark ? .dark : .light)
                .frame(width: width)
                // ImageRenderer does not resolve dynamic NSColors for dark mode;
                // use macOS's window background values directly.
                .background(look == .dark ? Color(white: 0.118) : Color(white: 0.925))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            image = renderer.nsImage
        }
        let rendered = try #require(image, "\(name) did not render")
        #expect(rendered.size.width > 0 && rendered.size.height > 0)

        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        if let tiff = rendered.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: Self.outputDirectory.appending(path: "\(name).png"))
        }
    }

    // MARK: - Connection states (USB missing, file-transfer mode, locked, unsupported, …)

    @Test(arguments: [
        ("waiting-file-transfer", ConnectionState.waitingForMTP(.fileTransferModeRequired)),
        ("waiting-ptp", .waitingForMTP(.ptpModeSelected)),
        ("locked", .waitingForMTP(.deviceLocked)),
        ("busy-conflict", .failed(.deviceBusy(owner: "ptpcamerad (pid 512)"))),
        ("session-failed", .failed(.sessionOpenFailed(detail: "LIBMTP_Open_Raw_Device_Uncached"))),
        ("unsupported-apple", .unsupported(.appleDevice)),
        ("reconnecting", .reconnecting),
        ("safely-disconnected", .safelyDisconnected),
    ])
    func deviceState(name: String, state: ConnectionState) throws {
        try renderMatrix("state-\(name)") { _ in DeviceStateContent(record: record(state)) }
    }

    @Test func noDeviceWelcome() throws {
        try renderMatrix("welcome") { _ in WelcomeContent() }
    }

    @Test func onboardingAndTroubleshooting() throws {
        try renderMatrix("onboarding", widths: [520]) { _ in OnboardingView() }
        try renderMatrix("troubleshooting", widths: [520]) { _ in TroubleshootingView() }
    }

    // MARK: - Transfers (success, failure with remedy, storage full, disconnected)

    @Test func transferRows() throws {
        func job(_ name: String, count: Int = 1, _ state: TransferJobState) -> TransferJob {
            let sources = (0..<count).map { URL(fileURLWithPath: "/tmp/\($0 == 0 ? name : "\(name)-\($0)")") }
            let destination = DeviceFolderRef(id: .root(deviceID: .demo, storageID: 1), path: ["DCIM"])
            let job = TransferJob(request: .upload(sources: sources, destination: destination, generation: 1, removeSourceAfter: false),
                                  destinationName: "DCIM")
            job.state = state
            return job
        }
        let running = job("가족 여행 2026.mov", .running)
        running.totalBytes = 4_000_000_000
        running.finishedBytes = 1_300_000_000
        running.bytesPerSecond = 31_000_000
        let jobs = [
            running,
            job("사진.jpg", count: 12, .completed),
            job("백업.zip", .failed(.insufficientDeviceSpace(required: 5_000_000_000, available: 1_200_000_000))),
            job("음성 메모.m4a", .failed(.disconnected)),
            job("문서.pdf", .cancelled),
        ]
        try renderMatrix("transfers", widths: [520, 760]) { _ in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(jobs) { TransferRow(job: $0) }
            }
            .padding(12)
        }
    }

    // MARK: - Finder problems

    @Test func finderProblems() throws {
        try renderMatrix("finder-problems", widths: [520]) { _ in
            VStack(alignment: .leading, spacing: 10) {
                FinderProblemView(problem: .extensionDisabled)
                FinderProblemView(problem: .serverUnavailable)
                FinderProblemView(problem: .filesOpen(detail: "EBUSY"))
                FinderProblemView(problem: .other(detail: "Resource busy"))
            }
            .padding(12)
        }
    }

    // MARK: - Conflicts

    @Test(arguments: AppLanguage.allCases)
    func conflictPrompt(language: AppLanguage) throws {
        let model = model(language: language)
        let conflict = TransferConflict(kind: .upload, name: "가족사진.jpg", isFolder: false, destinationName: "KakaoTalk",
                                        existingSize: 1_820_441, existingModified: Date(timeIntervalSince1970: 1_790_000_000),
                                        incomingSize: 2_048_000, incomingModified: Date(timeIntervalSince1970: 1_790_500_000),
                                        canReplace: true)
        for look in Look.allCases {
            try render(ConflictSheet(conflict: conflict), model: model, name: "conflict-\(language.rawValue)-\(look.rawValue)",
                       look: look)
        }
    }

    @Test func inspectorStepsAsideWhenTheWindowIsNarrow() {
        // 900 pt window, 220 pt sidebar → 680 pt detail.
        #expect(Layout.inspectorFits(detailWidth: 680, dualPane: false))
        #expect(!Layout.inspectorFits(detailWidth: 680, dualPane: true), "Android + Mac + inspector need more room")
        #expect(Layout.inspectorFits(detailWidth: 1_050, dualPane: true))
        #expect(Layout.sidebarMin + Layout.androidPaneMin + Layout.macPaneMin + 2 <= Layout.windowMinWidth,
                "both panes fit the smallest window without the inspector")
    }

    @Test func splitKeepsBothPanesUsable() {
        #expect(Layout.androidWidth(total: 1_000, fraction: 0.55) == 999 * 0.55)
        #expect(Layout.androidWidth(total: 700, fraction: 0.15) == Layout.androidPaneMin)
        #expect(Layout.androidWidth(total: 700, fraction: 0.85) == 699 - Layout.macPaneMin)
    }

    // MARK: - Strings never fall back to keys

    @Test(arguments: AppLanguage.allCases)
    func statesAndRemediesAreTranslated(language: AppLanguage) {
        let loc = model(language: language).localization
        for state: ConnectionState in [.safelyDisconnected, .waitingForMTP(.deviceLocked), .unsupported(.ptpCamera)] {
            #expect(!loc.stateTitle(state).hasPrefix("state."))
        }
        for error: DeviceError in [.insufficientDeviceSpace(required: 1, available: 0), .disconnected, .usbError(code: 1, detail: nil),
                                   .readOnlyStorage, .deviceBusy(owner: nil), .sessionOpenFailed(detail: nil)] {
            let remedy = loc.remedy(for: error)
            #expect(remedy != nil && !(remedy ?? "").hasPrefix("remedy."), "\(language) \(error)")
        }
    }
}
