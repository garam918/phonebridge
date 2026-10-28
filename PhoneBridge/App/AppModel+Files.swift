import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Copy / cut buffer for file operations inside PhoneBridge.
struct FileClipboard: Equatable {
    enum Source: Equatable {
        case device(items: [DeviceItemRef], generation: UInt64)
        case local([URL])
    }

    var source: Source
    var isCut: Bool
    /// NSPasteboard change count when this was copied; a newer system
    /// clipboard (e.g. files copied in Finder) takes precedence on paste.
    var pasteboardChangeCount: Int
}

enum FileDialog: Identifiable, Equatable {
    case newFolder
    case rename(FileItem)
    case confirmDelete([FileItem])
    /// Safe disconnect while `Int` transfers are running.
    case confirmDisconnect(DeviceID, Int)

    var id: String {
        switch self {
        case .newFolder: "newFolder"
        case .rename(let item): "rename-\(item.id)"
        case .confirmDelete(let items): "delete-\(items.map(\.id.description).joined())"
        case .confirmDisconnect(let id, _): "disconnect-\(id.rawValue)"
        }
    }
}

/// In-app drag payload, carried as plain text so it needs no exported UTType.
struct DragPayload: Codable, Equatable {
    static let prefix = "phonebridge-drag:"

    var deviceID: DeviceID?
    var generation: UInt64?
    var deviceItems: [DeviceItemRef] = []
    var localURLs: [URL] = []

    func encoded() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + data.base64EncodedString()
    }

    static func decode(_ string: String) -> DragPayload? {
        guard string.hasPrefix(prefix), let data = Data(base64Encoded: String(string.dropFirst(prefix.count))) else { return nil }
        return try? JSONDecoder().decode(DragPayload.self, from: data)
    }
}

/// Identifies the selection a cached drag payload was built from.
struct DragPayloadKey: Equatable {
    var selection: Set<FileItemID>
    var listingVersion: Int
    var generation: UInt64?
    var folder: FileItemID?
    var search: String
    var scope: SearchScope
}

/// What a device row or icon drags. Inside PhoneBridge the drop reads the
/// text payload (the whole selection); Finder and other apps get a file
/// promise for this one item, filled by downloading it when they accept the
/// drop. The file representations come first so receivers prefer the file
/// over the text (Finder would otherwise make a text clipping).
struct DeviceDragItem: Transferable, Identifiable {
    var item: DeviceItemRef
    var generation: UInt64
    var payload: DragPayload
    var exporter: DeviceDragExporter

    var id: FileItemID { item.id }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { drag in
            SentTransferredFile(try await drag.exporter.export(drag.item, generation: drag.generation))
        }
        .suggestedFileName { $0.item.name }
        .exportingCondition { !$0.item.isFolder }
        FileRepresentation(exportedContentType: .folder) { drag in
            SentTransferredFile(try await drag.exporter.export(drag.item, generation: drag.generation))
        }
        .suggestedFileName { $0.item.name }
        .exportingCondition { $0.item.isFolder }
        DataRepresentation(exportedContentType: .utf8PlainText) { drag in
            Data(drag.payload.encoded().utf8)
        }
    }
}

enum DropLoader {
    struct Contents {
        var fileURLs: [URL] = []
        var payloads: [DragPayload] = []
    }

    @MainActor
    static func load(_ providers: [NSItemProvider]) async -> Contents {
        var contents = Contents()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url, url.isFileURL { contents.fileURLs.append(url) }
            } else if provider.canLoadObject(ofClass: String.self) {
                let text: String? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
                }
                // Every row of a multi-row drag carries the same selection payload.
                if let text, let payload = DragPayload.decode(text), !contents.payloads.contains(payload) {
                    contents.payloads.append(payload)
                }
            }
        }
        return contents
    }

    static let acceptedTypes: [UTType] = [.fileURL, .utf8PlainText, .plainText]

    /// PhoneBridge's own drag payloads on `pasteboard` (empty for drags from
    /// other apps). Reads only the text type, never a file promise.
    static func inAppPayloads(_ pasteboard: NSPasteboard) -> [DragPayload] {
        var payloads: [DragPayload] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let text = item.string(forType: .string), let payload = DragPayload.decode(text),
                  !payloads.contains(payload) else { continue }
            payloads.append(payload)
        }
        return payloads
    }
}

extension AppModel {
    // MARK: - Capabilities of the current location

    var canWriteHere: Bool {
        guard let fileSystem = browser.fileSystem, browser.currentFolder != nil else { return false }
        return fileSystem.capabilities.canWrite && browser.storage?.isReadOnly != true
    }

    /// Delete (and cut) also work on devices that cannot be written to (iPhone photos).
    var canDeleteHere: Bool {
        guard let fileSystem = browser.fileSystem, browser.currentFolder != nil else { return false }
        return fileSystem.capabilities.canDelete && browser.storage?.isReadOnly != true
    }

    var canRenameHere: Bool {
        canWriteHere && browser.fileSystem?.capabilities.canRename == true
    }

    var hasDeviceSelection: Bool { !browser.selectedItems.isEmpty }

    // MARK: - Transfers

    func download(_ items: [FileItem], to destination: URL? = nil, deleteSource: Bool = false) {
        guard let fileSystem = browser.fileSystem, !items.isEmpty else { return }
        let target = destination ?? (settings.dualPane ? local.currentURL : nil) ?? localAccess.defaultFolder
        transfers.enqueue(.download(items: items.map(browser.reference), generation: fileSystem.generation,
                                    destination: target, deleteSourceAfter: deleteSource),
                          destinationName: target.lastPathComponent)
    }

    func upload(_ urls: [URL], to folder: DeviceFolderRef? = nil, removeSource: Bool = false) {
        guard let fileSystem = browser.fileSystem, let folder = folder ?? browser.currentFolderRef, !urls.isEmpty else { return }
        guard canWriteHere else {
            operationError = browser.storage?.isReadOnly == true ? .readOnlyStorage : .unsupportedOperation
            return
        }
        transfers.enqueue(.upload(sources: urls, destination: folder, generation: fileSystem.generation,
                                  removeSourceAfter: removeSource),
                          destinationName: folder.path.last ?? browser.storage?.name ?? "")
    }

    // MARK: - Folder / rename / delete

    @discardableResult
    func createFolder(named rawName: String) async -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fileSystem = browser.fileSystem, let folder = browser.currentFolder else { return false }
        if let error = FileNameRules.validationError(for: name) {
            operationError = error
            return false
        }
        do throws(DeviceError) {
            let created = try await fileSystem.createFolder(named: name, in: folder)
            await browser.reload()
            browser.selection = [created.id]
            return true
        } catch {
            operationError = error
            return false
        }
    }

    @discardableResult
    func rename(_ item: FileItem, to rawName: String) async -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fileSystem = browser.fileSystem, name != item.name else { return true }
        if let error = FileNameRules.validationError(for: name) {
            operationError = error
            return false
        }
        do throws(DeviceError) {
            let renamed = try await fileSystem.rename(item.id, to: name)
            await browser.reload()
            browser.selection = [renamed.id]
            return true
        } catch {
            operationError = error
            return false
        }
    }

    func requestDelete(_ items: [FileItem]) {
        guard !items.isEmpty, canDeleteHere else { return }
        activeDialog = .confirmDelete(items)
    }

    func delete(_ items: [FileItem]) {
        guard let fileSystem = browser.fileSystem, !items.isEmpty else { return }
        transfers.enqueue(.delete(items: items.map(browser.reference), generation: fileSystem.generation),
                          destinationName: browser.path.last?.name ?? "")
        browser.selection.subtract(items.map(\.id))
    }

    // MARK: - Clipboard

    func copyDeviceSelection(cut: Bool) {
        guard let fileSystem = browser.fileSystem, !browser.selectedItems.isEmpty else { return }
        let refs = browser.selectedItems.map(browser.reference)
        clipboard = FileClipboard(source: .device(items: refs, generation: fileSystem.generation), isCut: cut,
                                  pasteboardChangeCount: NSPasteboard.general.changeCount)
    }

    func copyLocalSelection(cut: Bool) {
        let urls = local.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        clipboard = FileClipboard(source: .local(urls), isCut: cut, pasteboardChangeCount: NSPasteboard.general.changeCount)
    }

    var canPasteIntoDevice: Bool {
        guard canWriteHere, let clipboard else { return false }
        if case .device(let items, _) = clipboard.source { return items.first?.id.deviceID == browser.deviceID }
        return true
    }

    var canPasteIntoLocal: Bool {
        guard local.currentURL != nil, let clipboard else { return false }
        if case .device = clipboard.source { return true }
        return false
    }

    func pasteIntoDevice() {
        guard let clipboard, let folder = browser.currentFolderRef else { return }
        switch clipboard.source {
        case .device(let items, let generation):
            guard items.first?.id.deviceID == browser.deviceID else {
                operationError = .unsupportedOperation
                return
            }
            transfers.enqueue(.deviceCopy(items: items, destination: folder, generation: generation, move: clipboard.isCut),
                              destinationName: folder.path.last ?? browser.storage?.name ?? "")
        case .local(let urls):
            upload(urls, to: folder, removeSource: clipboard.isCut)
        }
        if clipboard.isCut { self.clipboard = nil }
    }

    func pasteIntoLocal() {
        guard let clipboard, let destination = local.currentURL,
              case .device(let items, let generation) = clipboard.source else { return }
        transfers.enqueue(.download(items: items, generation: generation, destination: destination,
                                    deleteSourceAfter: clipboard.isCut),
                          destinationName: destination.lastPathComponent)
        if clipboard.isCut { self.clipboard = nil }
    }

    /// ⌘V in the Android pane: Finder-copied files win over an older
    /// in-app clipboard.
    func pasteCommandIntoDevice(_ providers: [NSItemProvider]) {
        if let clipboard, clipboard.pasteboardChangeCount == NSPasteboard.general.changeCount {
            pasteIntoDevice()
            return
        }
        Task {
            let contents = await DropLoader.load(providers)
            if !contents.fileURLs.isEmpty {
                upload(contents.fileURLs)
            } else if clipboard != nil {
                pasteIntoDevice()
            }
        }
    }

    // MARK: - Drag & drop

    func dragPayload(for item: FileItem) -> DragPayload {
        guard browser.selection.contains(item.id) else {
            return DragPayload(deviceID: browser.deviceID, generation: browser.generation, deviceItems: [browser.reference(for: item)])
        }
        let key = DragPayloadKey(selection: browser.selection, listingVersion: browser.listingVersion,
                                 generation: browser.generation, folder: browser.currentFolder,
                                 search: browser.searchText, scope: browser.searchScope)
        if let cached = dragPayloadCache, cached.key == key { return cached.payload }
        let payload = DragPayload(deviceID: browser.deviceID, generation: browser.generation,
                                  deviceItems: browser.selectedItems.map(browser.reference))
        dragPayloadCache = (key, payload)
        return payload
    }

    /// A device item as a drag source (in-app payload + file promise).
    func dragItem(for item: FileItem) -> DeviceDragItem {
        // A stale generation makes the download find the item again by path.
        DeviceDragItem(item: browser.reference(for: item), generation: browser.generation ?? 0,
                       payload: dragPayload(for: item), exporter: dragExporter)
    }

    /// Icon view: every selected item is dragged as its own file.
    func dragItems(_ ids: [FileItemID]) -> [DeviceDragItem] {
        let wanted = Set(ids)
        return browser.displayedItems.filter { wanted.contains($0.id) }.map(dragItem)
    }

    func localDragPayload(for item: LocalItem) -> String {
        let urls = local.selection.contains(item.url) ? local.selectedItems.map(\.url) : [item.url]
        return DragPayload(localURLs: urls).encoded()
    }

    /// Drop onto the Android pane (current folder) or onto a folder in it.
    func dropOnDevice(_ contents: DropLoader.Contents, onto folderItem: FileItem? = nil) {
        guard let current = browser.currentFolderRef else { return }
        let target = folderItem.map { DeviceFolderRef(id: $0.id, path: browser.parentPathNames(of: $0) + [$0.name]) } ?? current
        if !contents.fileURLs.isEmpty {
            upload(contents.fileURLs, to: target)
        }
        for payload in contents.payloads {
            if !payload.localURLs.isEmpty {
                upload(payload.localURLs, to: target)
            } else if let generation = payload.generation, !payload.deviceItems.isEmpty {
                guard payload.deviceID == browser.deviceID else {
                    operationError = .unsupportedOperation
                    continue
                }
                guard canWriteHere else { continue }
                // Dragging inside one device moves, like Finder on one volume.
                let items = payload.deviceItems.filter { $0.id != target.id }
                guard !items.isEmpty else { continue }
                transfers.enqueue(.deviceCopy(items: items, destination: target, generation: generation, move: true),
                                  destinationName: target.path.last ?? browser.storage?.name ?? "")
            }
        }
    }

    /// Drop onto the Mac pane: device items are downloaded there.
    func dropOnLocal(_ contents: DropLoader.Contents, into folder: URL? = nil) {
        guard let destination = folder ?? local.currentURL else { return }
        for payload in contents.payloads {
            guard let deviceID = payload.deviceID, let generation = payload.generation, !payload.deviceItems.isEmpty else { continue }
            guard deviceID == browser.deviceID else {
                operationError = .unsupportedOperation
                continue
            }
            transfers.enqueue(.download(items: payload.deviceItems, generation: generation, destination: destination,
                                        deleteSourceAfter: false),
                              destinationName: destination.lastPathComponent)
        }
    }

    // MARK: - Mac pane

    func toggleDualPane() {
        settings.dualPane.toggle()
        if settings.dualPane, local.currentURL == nil {
            Task { await local.open(root: localAccess.restoreLastFolder() ?? localAccess.defaultFolder) }
        }
    }

    func openLocalFolder(_ url: URL) async {
        localAccess.remember(url)
        await local.open(root: url)
    }

    // MARK: - Preview

    func previewSelection() async {
        if let item = browser.selectedItem, let fileSystem = browser.fileSystem {
            await previews.preview(item, in: fileSystem)
        }
    }

    func canPreview(_ item: FileItem?) -> Bool {
        guard let item else { return false }
        return previews.canPreview(item)
    }

    // MARK: - After transfers

    func transferFinished(_ job: TransferJob) {
        switch job.state {
        case .completed: post(.transferCompleted(job.title, job.itemCount))
        case .failed: post(.transferFailed(job.title, job.itemCount))
        default: break
        }
        if job.deviceID == browser.deviceID, job.kind != .download || job.request.isMoveFromDevice {
            Task { await browser.reload() }
        }
        switch job.request {
        case .download, .upload:
            Task { await local.reload() }
        default:
            break
        }
        if job.deviceID != .demo, job.deviceID == browser.deviceID {
            broker.refreshStorages(job.deviceID)
        }
    }
}

extension TransferRequest {
    var isMoveFromDevice: Bool {
        if case .download(_, _, _, true) = self { return true }
        return false
    }
}
