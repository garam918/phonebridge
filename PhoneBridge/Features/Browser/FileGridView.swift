import AppKit
import SwiftUI

struct FileGridView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 128), spacing: 12, alignment: .top)]

    var body: some View {
        let browser = model.browser
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(browser.displayedItems) { item in
                    GridCell(item: item, isSelected: browser.selection.contains(item.id))
                        .onTapGesture(count: 2) {
                            if item.isFolder {
                                Task { await browser.enter(item) }
                            } else if model.canPreview(item) {
                                browser.selection = [item.id]
                                Task { await model.previewSelection() }
                            }
                        }
                        .onTapGesture { select(item) }
                        // VoiceOver: select with VO-Space, open with the default action.
                        .accessibilityAction { select(item) }
                        .accessibilityAction(named: Text(loc.t(item.isFolder ? "action.open" : "action.preview"))) {
                            browser.selection = [item.id]
                            model.openSelection()
                        }
                        .modifier(GridDragSource(item: item))
                        .deviceFolderDrop(item, model: model)
                        .contextMenu {
                            FileContextMenu(ids: browser.selection.contains(item.id) ? browser.selection : [item.id])
                        }
                }
            }
            .modifier(GridDragContainer())
            .padding(16)
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { browser.selection = [] }
                .contextMenu { BackgroundMenuItems() }
        }
        .focusable()
    }

    /// ⌘-click toggles, ⇧-click extends, plain click selects one item.
    private func select(_ item: FileItem) {
        let browser = model.browser
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if browser.selection.contains(item.id) {
                browser.selection.remove(item.id)
            } else {
                browser.selection.insert(item.id)
            }
        } else if flags.contains(.shift), let anchor = browser.displayedItems.firstIndex(where: { browser.selection.contains($0.id) }),
                  let index = browser.displayedItems.firstIndex(of: item) {
            let range = min(anchor, index)...max(anchor, index)
            browser.selection.formUnion(browser.displayedItems[range].map(\.id))
        } else {
            browser.selection = [item.id]
        }
    }
}

private struct GridCell: View {
    let item: FileItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            FileIcon(item: item, size: 40)
                .frame(width: 64, height: 56)
                .background(isSelected ? Color.secondary.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor : .clear, in: .rect(cornerRadius: 4))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// macOS 26: an icon is part of a drag container (the whole selection goes,
/// each item as its own file). macOS 15: the icon drags itself; PhoneBridge's
/// own drop targets still receive the whole selection through its payload.
private struct GridDragSource: ViewModifier {
    @Environment(AppModel.self) private var model
    let item: FileItem

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.draggable(containerItemID: item.id)
        } else {
            content.draggable(model.dragItem(for: item))
        }
    }
}

private struct GridDragContainer: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let browser = model.browser
            content
                .dragContainer(for: DeviceDragItem.self) { ids in model.dragItems(ids) }
                .dragContainerSelection(browser.displayedItems.map(\.id).filter { browser.selection.contains($0) })
        } else {
            content
        }
    }
}

