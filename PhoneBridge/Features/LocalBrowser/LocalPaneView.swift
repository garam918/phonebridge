import AppKit
import SwiftUI

/// Mac side of the two-pane mode.
struct LocalPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    @State private var isDropTargeted = false
    @State private var sortOrder = [KeyPathComparator(\LocalItem.name, comparator: .localizedStandard)]

    var body: some View {
        let local = model.local
        VStack(spacing: 0) {
            header(local)
            Divider()
            Group {
                if let error = local.error {
                    ContentUnavailableView {
                        Label(loc.t("local.loadFailed"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loc.message(for: error))
                    } actions: {
                        Button(loc.t("local.chooseFolder")) { chooseFolder() }
                    }
                } else if local.currentURL == nil {
                    ContentUnavailableView {
                        Label(loc.t("local.noFolder"), systemImage: "folder")
                    } actions: {
                        Button(loc.t("local.chooseFolder")) { chooseFolder() }
                    }
                } else if local.items.isEmpty && !local.isLoading {
                    ContentUnavailableView(loc.t("browser.emptyFolder"), systemImage: "folder")
                } else {
                    table(local)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3).padding(2)
                }
            }
            .onDrop(of: DropLoader.acceptedTypes, isTargeted: $isDropTargeted) { providers in
                Task { model.dropOnLocal(await DropLoader.load(providers)) }
                return true
            }
        }
    }

    private func header(_ local: LocalBrowserViewModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
            Text(loc.t("local.title")).font(.headline)
            Text(local.currentURL?.lastPathComponent ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(local.currentURL?.path(percentEncoded: false) ?? "")
            Spacer()
            Button { Task { await local.goUp() } } label: { Image(systemName: "arrow.turn.left.up") }
                .disabled(!local.canGoUp)
                .help(loc.t("menu.go.enclosingFolder"))
            Button { Task { await local.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help(loc.t("menu.go.refresh"))
            Button(loc.t("local.chooseFolder")) { chooseFolder() }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private func table(_ local: LocalBrowserViewModel) -> some View {
        @Bindable var local = local
        return Table(of: LocalItem.self, selection: $local.selection, sortOrder: $sortOrder) {
            TableColumn(loc.t("column.name"), value: \.name, comparator: .localizedStandard) { item in
                Label {
                    Text(item.name).lineLimit(1)
                } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn(loc.t("column.modified"), value: \.modifiedSortKey) { item in
                Text(item.modified.map(loc.formatDate) ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn(loc.t("column.size"), value: \.sizeSortKey) { item in
                Text(item.isFolder ? "—" : item.size.map(loc.formatBytes) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
        } rows: {
            ForEach(local.items) { item in
                TableRow(item)
                    .draggable(model.localDragPayload(for: item))
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            localMenu(urls)
        } primaryAction: { urls in
            guard urls.count == 1, let item = local.items.first(where: { urls.contains($0.url) }) else { return }
            if item.isFolder {
                Task { await local.enter(item) }
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
        .onChange(of: sortOrder) { _, newValue in
            local.sort = Self.descriptor(from: newValue, current: local.sort)
        }
        .onKeyPress(.space) {
            guard let item = local.selectedItems.first, !item.isFolder else { return .ignored }
            model.previews.previewLocal(item.url)
            return .handled
        }
        .onCopyCommand {
            model.copyLocalSelection(cut: false)
            return local.selectedItems.map { NSItemProvider(object: $0.url as NSURL) }
        }
        .onCutCommand {
            model.copyLocalSelection(cut: true)
            return local.selectedItems.map { NSItemProvider(object: $0.url as NSURL) }
        }
        .onPasteCommand(of: DropLoader.acceptedTypes) { _ in
            model.pasteIntoLocal()
        }
    }

    @ViewBuilder
    private func localMenu(_ urls: Set<URL>) -> some View {
        let items = model.local.items.filter { urls.contains($0.url) }
        if !items.isEmpty {
            Button(loc.t("action.uploadToDevice")) { model.upload(items.map(\.url)) }
                .disabled(!model.canWriteHere)
            Divider()
            Button(loc.t("action.copy")) {
                model.local.selection = urls
                model.copyLocalSelection(cut: false)
            }
            Button(loc.t("action.cut")) {
                model.local.selection = urls
                model.copyLocalSelection(cut: true)
            }
            Divider()
            Button(loc.t("action.showInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
            }
            if items.count == 1, let item = items.first, !item.isFolder {
                Button(loc.t("action.preview")) { model.previews.previewLocal(item.url) }
            }
        }
        if model.canPasteIntoLocal {
            Button(loc.t("action.pasteHere")) { model.pasteIntoLocal() }
        }
    }

    private func chooseFolder() {
        guard let url = Panels.chooseFolder(prompt: loc.t("local.chooseFolder.prompt"), message: loc.t("local.chooseFolder.message"),
                                            startingAt: model.local.currentURL) else { return }
        Task { await model.openLocalFolder(url) }
    }

    static func descriptor(from comparators: [KeyPathComparator<LocalItem>], current: FileSortDescriptor) -> FileSortDescriptor {
        guard let first = comparators.first else { return current }
        var descriptor = current
        descriptor.ascending = first.order == .forward
        switch first.keyPath {
        case \LocalItem.modifiedSortKey: descriptor.key = .modified
        case \LocalItem.sizeSortKey: descriptor.key = .size
        default: descriptor.key = .name
        }
        return descriptor
    }
}
