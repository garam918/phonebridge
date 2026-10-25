import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: Layout.sidebarMin, ideal: 230, max: 320)
        } detail: {
            DetailView()
        }
        .modifier(FileDialogsModifier())
        .frame(minWidth: Layout.windowMinWidth, minHeight: 560)
    }
}

/// Column widths and the responsive rules between them.
///
/// The inspector is our own trailing column and the Android | Mac split is
/// our own proportional split, not SwiftUI's `.inspector` / `HSplitView`: on
/// macOS 27 that pair never settled its constraint passes and AppKit
/// terminated the app on every launch with the Mac pane shown (4차 개발).
enum Layout {
    static let windowMinWidth: CGFloat = 900
    static let sidebarMin: CGFloat = 180
    static let inspectorWidth: CGFloat = 240
    /// Narrowest useful file lists (name + one more column).
    static let androidPaneMin: CGFloat = 340
    static let macPaneMin: CGFloat = 260
    static let dividerWidth: CGFloat = 1

    /// The inspector steps aside when the panes would get narrower than their minimum.
    static func inspectorFits(detailWidth: CGFloat, dualPane: Bool) -> Bool {
        let panes = androidPaneMin + (dualPane ? macPaneMin + dividerWidth : 0)
        return detailWidth >= panes + dividerWidth + inspectorWidth
    }

    /// Android pane width for a split fraction, keeping both panes usable.
    static func androidWidth(total: CGFloat, fraction: Double) -> CGFloat {
        let usable = total - dividerWidth
        guard usable >= androidPaneMin + macPaneMin else { return max(0, usable * 0.5) }
        return min(max(usable * CGFloat(fraction), androidPaneMin), usable - macPaneMin)
    }
}

/// Android | Mac side by side; the divider is dragged to change the share,
/// which is kept in Settings. Proportional, so both panes grow with the window.
struct SplitPanes<Leading: View, Trailing: View>: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LocalizationManager.self) private var loc
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var dragStartFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let leadingWidth = Layout.androidWidth(total: total, fraction: settings.dualPaneFraction)
            HStack(spacing: 0) {
                leading.frame(width: leadingWidth)
                Divider()
                    .overlay {
                        Color.clear
                            .frame(width: 9)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let start = dragStartFraction ?? settings.dualPaneFraction
                                    dragStartFraction = start
                                    let usable = max(1, total - Layout.dividerWidth)
                                    settings.dualPaneFraction = min(0.85, max(0.15, start + Double(value.translation.width / usable)))
                                }
                                .onEnded { _ in dragStartFraction = nil })
                            .accessibilityLabel(loc.t("a11y.dualPaneSplit"))
                    }
                trailing.frame(maxWidth: .infinity)
            }
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    @Environment(AppSettings.self) private var settings
    @FocusState private var searchFocused: Bool
    @State private var detailWidth: CGFloat = 10_000

    var body: some View {
        @Bindable var browser = model.browser
        HStack(spacing: 0) {
            panesAndTransfers
            if model.showInspector, Layout.inspectorFits(detailWidth: detailWidth, dualPane: settings.dualPane) {
                Divider()
                InspectorView()
                    .frame(width: Layout.inspectorWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        .navigationTitle(title)
        .navigationSubtitle(model.detailContent == .browser ? (model.selectedDeviceName ?? "") : "")
        .toolbar { BrowserToolbar() }
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: loc.t("search.prompt"))
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .searchScopes($browser.searchScope) {
            Text(loc.t("search.scope.currentFolder")).tag(SearchScope.currentFolder)
            Text(loc.t("search.scope.subfolders")).tag(SearchScope.subfolders)
        }
    }

    private var panesAndTransfers: some View {
        VStack(spacing: 0) {
            Group {
                if settings.dualPane {
                    SplitPanes {
                        androidPane.frame(maxHeight: .infinity)
                    } trailing: {
                        LocalPaneView().frame(maxHeight: .infinity)
                    }
                } else {
                    androidPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            TransferBarView()
        }
    }

    @ViewBuilder
    private var androidPane: some View {
        switch model.detailContent {
        case .welcome:
            EmptyStateView()
        case .deviceState(let record):
            DeviceStateView(record: record)
        case .browser:
            BrowserView()
        }
    }

    private var title: String {
        if model.detailContent == .browser, let name = model.browser.path.last?.name { return name }
        return model.selectedDeviceName ?? "PhoneBridge"
    }
}
