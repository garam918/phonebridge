import SwiftUI

struct FileListView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    @State private var sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)]

    var body: some View {
        @Bindable var browser = model.browser
        let showsLocation = browser.isRecursiveSearchActive
        Table(of: FileItem.self, selection: $browser.selection, sortOrder: $sortOrder) {
            TableColumn(loc.t("column.name"), value: \.name, comparator: .localizedStandard) { item in
                Label {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.name).lineLimit(1)
                        if showsLocation {
                            Text(browser.locationDescription(of: item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    FileIcon(item: item)
                }
                .opacity(isCut(item) ? 0.5 : 1)
            }
            .width(min: 180, ideal: 320)
            TableColumn(loc.t("column.modified"), value: \.modifiedSortKey) { item in
                Text(item.modified.map(loc.formatDate) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 170)
            TableColumn(loc.t("column.size"), value: \.sizeSortKey) { item in
                Text(sizeText(item))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn(loc.t("column.kind"), value: \.kindSortKey) { item in
                Text(loc.t(item.category.localizationKey))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        } rows: {
            ForEach(browser.displayedItems) { item in
                TableRow(item)
                    .draggable(model.dragItem(for: item))
                    .dropDestination(for: String.self) { payloads in
                        model.dropOnDevice(strings: payloads, onto: item)
                    }
            }
        }
        .contextMenu(forSelectionType: FileItemID.self) { ids in
            FileContextMenu(ids: ids)
        } primaryAction: { ids in
            openIfSingle(ids)
        }
        .onChange(of: sortOrder) { _, newValue in
            browser.sort = Self.descriptor(from: newValue, current: browser.sort)
        }
    }

    private func isCut(_ item: FileItem) -> Bool {
        guard let clipboard = model.clipboard, clipboard.isCut, case .device(let items, _) = clipboard.source else { return false }
        return items.contains { $0.id == item.id }
    }

    private func sizeText(_ item: FileItem) -> String {
        guard !item.isFolder, let size = item.size else { return "—" }
        return loc.formatBytes(size)
    }

    private func openIfSingle(_ ids: Set<FileItemID>) {
        guard ids.count == 1, let item = model.browser.displayedItems.first(where: { ids.contains($0.id) }) else { return }
        if item.isFolder {
            Task { await model.browser.enter(item) }
        } else if model.canPreview(item) {
            model.browser.selection = [item.id]
            Task { await model.previewSelection() }
        }
    }

    static func descriptor(from comparators: [KeyPathComparator<FileItem>], current: FileSortDescriptor) -> FileSortDescriptor {
        guard let first = comparators.first else { return current }
        var descriptor = current
        descriptor.ascending = first.order == .forward
        switch first.keyPath {
        case \FileItem.modifiedSortKey: descriptor.key = .modified
        case \FileItem.sizeSortKey: descriptor.key = .size
        case \FileItem.kindSortKey: descriptor.key = .kind
        default: descriptor.key = .name
        }
        return descriptor
    }
}

struct FileIcon: View {
    let item: FileItem
    var size: CGFloat?

    var body: some View {
        Image(systemName: item.category.symbolName)
            .font(size.map { .system(size: $0) } ?? .body)
            .foregroundStyle(item.isFolder ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .symbolRenderingMode(.hierarchical)
    }
}

/// Context menu for selected device items (or the empty area).
struct FileContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let ids: Set<FileItemID>

    var body: some View {
        let items = model.browser.displayedItems.filter { ids.contains($0.id) }
        if items.isEmpty {
            BackgroundMenuItems()
        } else {
            if items.count == 1, let item = items.first {
                if item.isFolder {
                    Button(loc.t("action.open")) { Task { await model.browser.enter(item) } }
                } else if model.canPreview(item) {
                    Button(loc.t("action.preview")) {
                        model.browser.selection = [item.id]
                        Task { await model.previewSelection() }
                    }
                }
                Divider()
            }
            Button(loc.t("action.downloadToDefault", model.localAccess.defaultFolder.lastPathComponent)) {
                FileActions.download(items, model: model, loc: loc, choosingDestination: false)
            }
            Button(loc.t("action.downloadTo")) {
                FileActions.download(items, model: model, loc: loc, choosingDestination: true)
            }
            Divider()
            Button(loc.t("action.copy")) {
                model.browser.selection = ids
                model.copyDeviceSelection(cut: false)
            }
            Button(loc.t("action.cut")) {
                model.browser.selection = ids
                model.copyDeviceSelection(cut: true)
            }
            .disabled(!model.canWriteHere)
            if model.canPasteIntoDevice {
                Button(loc.t("action.pasteHere")) { model.pasteIntoDevice() }
            }
            Divider()
            if items.count == 1, let item = items.first {
                Button(loc.t("action.renameEllipsis")) { model.activeDialog = .rename(item) }
                    .disabled(!model.canRenameHere)
            }
            Button(loc.t("action.deleteEllipsis")) { model.requestDelete(items) }
                .disabled(!model.canWriteHere)
            Divider()
            Button(loc.t("action.getInfo")) {
                model.browser.selection = ids
                model.showInspector = true
            }
        }
    }
}

struct BackgroundMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Button(loc.t("action.newFolderEllipsis")) { model.activeDialog = .newFolder }
            .disabled(!model.canWriteHere)
        Button(loc.t("action.uploadEllipsis")) { FileActions.upload(model: model, loc: loc) }
            .disabled(!model.canWriteHere)
        if model.canPasteIntoDevice {
            Button(loc.t("action.pasteHere")) { model.pasteIntoDevice() }
        }
    }
}
