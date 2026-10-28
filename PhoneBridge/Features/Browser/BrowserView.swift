import AppKit
import SwiftUI

/// Android pane: listing, search, drop target, file commands.
struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    @Environment(AppSettings.self) private var settings
    @State private var isDropTargeted = false

    var body: some View {
        let browser = model.browser
        VStack(spacing: 0) {
            if browser.isShowingMock {
                Banner(symbol: "testtube.2", text: loc.t("demo.banner"), tint: .orange)
                Divider()
            }
            if browser.fileSystem is ImageCaptureFileSystem {
                Banner(symbol: "photo.on.rectangle", text: loc.t("browser.applePhotos"), tint: .secondary)
                Divider()
            } else if browser.storage?.isReadOnly == true || browser.fileSystem?.capabilities.canWrite == false {
                Banner(symbol: "lock", text: loc.t("browser.readOnly"), tint: .secondary)
                Divider()
            }
            if browser.isRecursiveSearchActive {
                SearchStatus()
                Divider()
            }
            content(browser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if isDropTargeted && model.canWriteHere {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3).padding(2)
                    }
                }
                .onDrop(of: DropLoader.acceptedTypes,
                        delegate: InAppFirstDropDelegate(isTargeted: $isDropTargeted, isEnabled: { model.canWriteHere }) {
                            model.dropOnDevice($0)
                        })
                .accessibilityHint(model.canWriteHere ? loc.t("a11y.dropTarget") : "")
            Divider()
            PathBarView()
        }
    }

    @ViewBuilder
    private func content(_ browser: BrowserViewModel) -> some View {
        switch browser.phase {
        case .failed(let error):
            ContentUnavailableView {
                Label(loc.t("browser.loadFailed"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(loc.message(for: error))
            } actions: {
                Button(loc.t("action.retry")) { model.refresh() }
            }
        case .loading where browser.items.isEmpty, .idle:
            ProgressView(loc.t("browser.loading"))
                .controlSize(.small)
        default:
            if browser.displayedItems.isEmpty {
                Group {
                    if browser.searchText.isEmpty {
                        ContentUnavailableView(loc.t("browser.emptyFolder"), systemImage: "folder")
                    } else if browser.isSearching {
                        ProgressView(loc.t("search.searching"))
                    } else {
                        // Not ContentUnavailableView.search: its text follows the system language.
                        ContentUnavailableView(loc.t("search.noResults", browser.searchText), systemImage: "magnifyingglass",
                                               description: Text(loc.t("search.noResults.description")))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .contextMenu { BackgroundMenuItems() }
            } else if settings.viewMode == .grid {
                FileGridView().modifier(FileCommandsModifier())
            } else {
                FileListView().modifier(FileCommandsModifier())
            }
        }
    }
}

private struct Banner: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08))
    }
}

private struct SearchStatus: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        let browser = model.browser
        HStack(spacing: 6) {
            if browser.isSearching {
                ProgressView().controlSize(.small)
                Text(loc.t("search.searchingIn", browser.path.last?.name ?? ""))
            } else {
                Image(systemName: "magnifyingglass")
                Text(loc.t("search.resultCount", browser.searchResults.count))
                if browser.searchResults.count >= BrowserViewModel.searchResultLimit {
                    Text(loc.t("search.limitReached")).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

/// Keyboard and Edit-menu commands for the device listing.
struct FileCommandsModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onKeyPress(.space) {
                guard model.canPreview(model.browser.selectedItem) else { return .ignored }
                Task { await model.previewSelection() }
                return .handled
            }
            .onKeyPress(.return) {
                guard model.canRenameHere, let item = model.browser.selectedItem else { return .ignored }
                model.activeDialog = .rename(item)
                return .handled
            }
            .onDeleteCommand {
                model.requestDelete(model.browser.selectedItems)
            }
            .onCopyCommand {
                model.copyDeviceSelection(cut: false)
                return model.browser.selectedItems.map { NSItemProvider(object: $0.name as NSString) }
            }
            .onCutCommand {
                guard model.canDeleteHere else { return [] }
                model.copyDeviceSelection(cut: true)
                return model.browser.selectedItems.map { NSItemProvider(object: $0.name as NSString) }
            }
            .onPasteCommand(of: DropLoader.acceptedTypes) { providers in
                guard model.canWriteHere else { return }
                model.pasteCommandIntoDevice(providers)
            }
    }
}

/// Actions that need a panel or a sheet; shared by menus, toolbar and commands.
@MainActor
enum FileActions {
    static func upload(model: AppModel, loc: LocalizationManager) {
        let urls = Panels.chooseItemsToUpload(prompt: loc.t("action.upload"), message: loc.t("panel.upload.message"))
        model.upload(urls)
    }

    static func download(_ items: [FileItem], model: AppModel, loc: LocalizationManager, choosingDestination: Bool) {
        guard !items.isEmpty else { return }
        if choosingDestination {
            guard let url = Panels.chooseFolder(prompt: loc.t("action.download"), message: loc.t("panel.download.message"),
                                                startingAt: model.localAccess.defaultFolder) else { return }
            model.download(items, to: url)
        } else {
            model.download(items)
        }
    }
}

struct BrowserToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    @Environment(AppSettings.self) private var settings

    var body: some ToolbarContent {
        let browser = model.browser
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await browser.goBack() } } label: {
                Label(loc.t("menu.go.back"), systemImage: "chevron.left")
            }
            .disabled(!browser.canGoBack)
            .help(loc.t("menu.go.back"))
            Button { Task { await browser.goForward() } } label: {
                Label(loc.t("menu.go.forward"), systemImage: "chevron.right")
            }
            .disabled(!browser.canGoForward)
            .help(loc.t("menu.go.forward"))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            @Bindable var settings = settings
            Picker(loc.t("toolbar.viewMode"), selection: $settings.viewMode) {
                Label(loc.t("menu.view.asList"), systemImage: "list.bullet").tag(BrowserViewMode.list)
                Label(loc.t("menu.view.asGrid"), systemImage: "square.grid.2x2").tag(BrowserViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help(loc.t("toolbar.viewMode"))
            Button { model.toggleDualPane() } label: {
                Label(loc.t("toolbar.dualPane"), systemImage: settings.dualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            }
            .help(loc.t("toolbar.dualPane"))
            Button { model.activeDialog = .newFolder } label: {
                Label(loc.t("action.newFolder"), systemImage: "folder.badge.plus")
            }
            .disabled(!model.canWriteHere)
            .help(loc.t("action.newFolder"))
            Button { FileActions.upload(model: model, loc: loc) } label: {
                Label(loc.t("action.upload"), systemImage: "square.and.arrow.up")
            }
            .disabled(!model.canWriteHere)
            .help(loc.t("action.upload.help"))
            Button { FileActions.download(browser.selectedItems, model: model, loc: loc, choosingDestination: false) } label: {
                Label(loc.t("action.download"), systemImage: "square.and.arrow.down")
            }
            .disabled(!model.hasDeviceSelection)
            .help(loc.t("action.download.help"))
            Button { model.requestDelete(browser.selectedItems) } label: {
                Label(loc.t("action.delete"), systemImage: "trash")
            }
            .disabled(!model.hasDeviceSelection || !model.canWriteHere)
            .help(loc.t("action.delete"))
            Button { model.refresh() } label: {
                Label(loc.t("menu.go.refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(browser.fileSystem == nil)
            .help(loc.t("menu.go.refresh"))
            Button { model.showInspector.toggle() } label: {
                Label(loc.t("toolbar.inspector"), systemImage: "info.circle")
            }
            .help(loc.t("toolbar.inspector"))
        }
    }
}

struct PathBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        let browser = model.browser
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let name = model.selectedDeviceName {
                    Label(name, systemImage: browser.isShowingMock ? "testtube.2" : "smartphone")
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                }
                ForEach(Array(browser.path.enumerated()), id: \.element) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    }
                    Button {
                        Task { await browser.goToPathIndex(index) }
                    } label: {
                        Label(component.name, systemImage: index == 0 ? storageSymbol(browser.storage) : "folder")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == browser.path.count - 1)
                }
            }
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .padding(.horizontal, 12)
        }
        .frame(height: 26)
        .background(.bar)
    }

    private func storageSymbol(_ storage: StorageInfo?) -> String {
        storage?.kind == .removable ? "sdcard" : "internaldrive"
    }
}
