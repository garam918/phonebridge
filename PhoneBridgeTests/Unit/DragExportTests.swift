import AppKit
import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PhoneBridge

/// Android → Finder drag (file promise) on the virtual device. A real Finder
/// drop cannot be scripted without accessibility access; these tests drive
/// the same item provider a drop reads from.
@MainActor
@Suite("Drag to Finder (virtual device)")
struct DragExportTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "DragExportTests-\(UUID().uuidString)",
                                                                       directoryHint: .isDirectory)

    private func makeModel(demo: MockDeviceFileSystem = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree()))
        async throws -> AppModel {
        let defaults = freshDefaults()
        defaults.set(true, forKey: AppSettings.Key.showDemoDevice)
        let broker = DeviceBroker(monitor: MockUSBMonitor(), backend: MockMTPBackend())
        let model = AppModel(broker: broker, localization: LocalizationManager(defaults: defaults),
                             settings: AppSettings(defaults: defaults), demoDevice: demo,
                             localAccess: LocalAccessManager(defaults: defaults, defaultFolder: FileManager.default.temporaryDirectory),
                             dragDirectory: directory)
        await model.start(startBroker: false)
        try await waitUntil { model.browser.phase == .loaded }
        return model
    }

    private func enter(_ name: String, in model: AppModel) async throws {
        let folder = try #require(model.browser.items.first { $0.name == name })
        await model.browser.enter(folder)
        try await waitUntil { model.browser.phase == .loaded && model.browser.path.last?.name == name }
    }

    private func item(_ name: String, in model: AppModel) throws -> FileItem {
        try #require(model.browser.displayedItems.first { $0.name == name })
    }

    private func loadFile(_ provider: NSItemProvider, type: UTType) async throws -> (name: String, data: Data?, children: [String]) {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                // The URL is only valid inside this handler.
                let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
                continuation.resume(returning: (url.lastPathComponent, try? Data(contentsOf: url), children.sorted()))
            }
        }
    }

    // MARK: - Export

    @Test func fileIsDownloadedThroughTheQueueUnderItsOwnName() async throws {
        let model = try await makeModel()
        try await enter("Documents", in: model)
        let memo = try item("메모.txt", in: model)

        let url = try await model.dragExporter.export(model.browser.reference(for: memo), generation: model.browser.generation ?? 0)
        #expect(url.lastPathComponent == "메모.txt")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent() == directory)
        #expect(LocalFileIO.fileSize(url) == memo.size)

        let job = try #require(model.transfers.jobs.last)
        #expect(job.isDragExport && job.state == .completed && job.kind == .download)
        #expect(!job.canRetry, "the receiving app has gone by the time a drag export fails")
    }

    @Test func folderIsExportedWithItsContents() async throws {
        let model = try await makeModel()
        let documents = try item("Documents", in: model)
        let url = try await model.dragExporter.export(model.browser.reference(for: documents), generation: model.browser.generation ?? 0)
        #expect(url.lastPathComponent == "Documents")
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)).sorted()
        #expect(names == ["가계부 2026.xlsx", "메모.txt", "빈 폴더"].sorted())
    }

    @Test func failedDownloadThrowsAndLeavesNothingBehind() async throws {
        let demo = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree())
        let model = try await makeModel(demo: demo)
        try await enter("Documents", in: model)
        let memo = try item("메모.txt", in: model)
        demo.configureFaults { $0.failing[.download] = .usbError(code: -7, detail: "mock") }

        await #expect(throws: DeviceError.usbError(code: -7, detail: "mock")) {
            _ = try await model.dragExporter.export(model.browser.reference(for: memo), generation: model.browser.generation ?? 0)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        #expect(left.isEmpty)
    }

    @Test func cancellingTheJobCancelsTheExport() async throws {
        let demo = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree(),
                                        faults: .init(chunkSize: 64 << 10, chunkDelay: .milliseconds(5)))
        let model = try await makeModel(demo: demo)
        try await enter("Download", in: model)
        let apk = try item("app-release.apk", in: model)

        let export = Task { try await model.dragExporter.export(model.browser.reference(for: apk), generation: model.browser.generation ?? 0) }
        try await waitUntil { model.transfers.runningJob?.isDragExport == true }
        model.transfers.cancel(try #require(model.transfers.runningJob))
        await #expect(throws: DeviceError.cancelled) { _ = try await export.value }
    }

    @Test func itemsDroppedTogetherBecomeOneTransferJob() async throws {
        let model = try await makeModel()
        try await enter("Documents", in: model)
        let refs = try ["메모.txt", "가계부 2026.xlsx", "빈 폴더"].map { model.browser.reference(for: try item($0, in: model)) }
        let generation = model.browser.generation ?? 0

        async let first = model.dragExporter.export(refs[0], generation: generation)
        async let second = model.dragExporter.export(refs[1], generation: generation)
        async let third = model.dragExporter.export(refs[2], generation: generation)
        let urls = try await [first, second, third]

        #expect(model.transfers.jobs.count == 1, "one row in the transfer list")
        #expect(model.transfers.jobs.first?.itemCount == 3)
        #expect(Set(urls.map { $0.deletingLastPathComponent() }).count == 1, "one private folder")
        #expect(urls.map(\.lastPathComponent) == ["메모.txt", "가계부 2026.xlsx", "빈 폴더"])
        #expect(LocalFileIO.fileSize(urls[0]) == 2_048)
    }

    @Test func sameNamesFromDifferentFoldersGoToSeparateJobs() async throws {
        let model = try await makeModel()
        // DCIM on internal storage and on the SD card share the name.
        let internalDCIM = try item("DCIM", in: model)
        let sd = try #require(model.demoStorages.first { $0.id != model.browser.storage?.id })
        await model.browser.open(model.demoDevice, storage: sd)
        try await waitUntil { model.browser.phase == .loaded }
        let sdDCIM = try item("DCIM", in: model)
        let generation = model.browser.generation ?? 0

        async let a = model.dragExporter.export(DeviceItemRef(item: internalDCIM, parentPath: []), generation: generation)
        async let b = model.dragExporter.export(DeviceItemRef(item: sdDCIM, parentPath: []), generation: generation)
        let urls = try await [a, b]
        #expect(model.transfers.jobs.count == 2)
        #expect(Set(urls).count == 2)
        #expect(model.transfers.pendingConflict == nil, "no name conflict prompt")
    }

    @Test func oneFailedItemDoesNotCancelFilesThatArrived() async throws {
        let demo = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree())
        let model = try await makeModel(demo: demo)
        try await enter("Documents", in: model)
        let memo = model.browser.reference(for: try item("메모.txt", in: model))
        let budget = model.browser.reference(for: try item("가계부 2026.xlsx", in: model))
        // The second download fails (items run in drop order).
        demo.configureFaults { $0.failingCall[.download] = (call: 2, error: .usbError(code: -7, detail: "mock")) }

        let generation = model.browser.generation ?? 0
        let exporter = model.dragExporter
        let first = Task { try await exporter.export(memo, generation: generation) }
        let second = Task { try await exporter.export(budget, generation: generation) }
        let delivered = try await first.value
        #expect(LocalFileIO.fileSize(delivered) == 2_048)
        await #expect(throws: DeviceError.usbError(code: -7, detail: "mock")) { _ = try await second.value }
        #expect(model.transfers.jobs.count == 1)
    }

    @Test func oldPrivateCopiesAreRemoved() throws {
        let exporter = DeviceDragExporter(transfers: TransferManager(fileSystemProvider: { _ in nil }), directory: directory)
        let old = directory.appending(path: "old"), recent = directory.appending(path: "recent")
        for folder in [old, recent] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: old.path(percentEncoded: false))

        exporter.removeOld()
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: recent.path(percentEncoded: false)))
        exporter.removeOld(olderThan: 0)
        #expect(!FileManager.default.fileExists(atPath: recent.path(percentEncoded: false)))
    }

    // MARK: - What the drag carries

    @Test func fileDragOffersAFilePromiseBeforeTheInAppText() async throws {
        let model = try await makeModel()
        try await enter("Documents", in: model)
        let memo = try item("메모.txt", in: model)
        let drag = model.dragItem(for: memo)

        let provider = NSItemProvider()
        provider.register(drag)
        #expect(provider.registeredTypeIdentifiers.first == UTType.data.identifier, "\(provider.registeredTypeIdentifiers)")
        #expect(provider.registeredTypeIdentifiers.contains(UTType.utf8PlainText.identifier))
        #expect(!provider.registeredTypeIdentifiers.contains(UTType.folder.identifier))
        #expect(!provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                "PhoneBridge's own drop targets must keep reading the text payload")

        // What Finder does on drop: ask for the file.
        let file = try await loadFile(provider, type: .data)
        #expect(file.data?.count == Int(memo.size ?? 0))
        #expect(model.transfers.jobs.last?.isDragExport == true)
    }

    @Test func folderDragOffersAFolder() async throws {
        let model = try await makeModel()
        let documents = try item("Documents", in: model)
        let drag = model.dragItem(for: documents)
        let provider = NSItemProvider()
        provider.register(drag)
        #expect(provider.registeredTypeIdentifiers.first == UTType.folder.identifier, "\(provider.registeredTypeIdentifiers)")

        let folder = try await loadFile(provider, type: .folder)
        #expect(folder.children == ["가계부 2026.xlsx", "메모.txt", "빈 폴더"].sorted())
    }

    @Test func inAppDropsStillReadTheSelectionPayloadOnce() async throws {
        let model = try await makeModel()
        try await enter("Documents", in: model)
        let memo = try item("메모.txt", in: model), budget = try item("가계부 2026.xlsx", in: model)
        model.browser.selection = [memo.id, budget.id]

        // A two-row drag: each row carries the same selection payload.
        let providers = [memo, budget].map { file in
            let drag = model.dragItem(for: file)
            let provider = NSItemProvider()
            provider.register(drag)
            return provider
        }
        let contents = await DropLoader.load(providers)
        #expect(contents.fileURLs.isEmpty)
        #expect(contents.payloads.count == 1)
        #expect(Set(contents.payloads.first?.deviceItems.map(\.name) ?? []) == ["메모.txt", "가계부 2026.xlsx"])
        #expect(model.transfers.jobs.isEmpty, "an in-app drop must not download through the promise")
    }

    /// Stands in for the file promise on a real drag pasteboard: on a drop in
    /// the same app, asking for it blocked the main thread for good (D77).
    final class PromiseTrap: NSObject, NSPasteboardItemDataProvider {
        private(set) var askedTypes: [NSPasteboard.PasteboardType] = []

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            askedTypes.append(type)
            item.setString("file:///promised", forType: type)
        }
    }

    private func dragPasteboard(_ texts: [String], trap: PromiseTrap) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DragExportTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let items = texts.map { text in
            let item = NSPasteboardItem()
            item.setDataProvider(trap, forTypes: [.fileURL])
            item.setString(text, forType: .string)
            return item
        }
        pasteboard.writeObjects(items)
        return pasteboard
    }

    @Test func paneDropsReadInAppDragsWithoutTouchingTheFilePromise() async throws {
        let model = try await makeModel()
        try await enter("Documents", in: model)
        let memo = try item("메모.txt", in: model), budget = try item("가계부 2026.xlsx", in: model)
        model.browser.selection = [memo.id, budget.id]
        let payload = model.dragPayload(for: memo).encoded()
        let trap = PromiseTrap()
        let pasteboard = dragPasteboard([payload, payload], trap: trap)
        defer { pasteboard.releaseGlobally() }

        let payloads = DropLoader.inAppPayloads(pasteboard)
        #expect(payloads.count == 1, "both rows carry the same selection")
        #expect(Set(payloads.first?.deviceItems.map(\.name) ?? []) == ["메모.txt", "가계부 2026.xlsx"])
        #expect(trap.askedTypes.isEmpty, "the file promise is for Finder, not for PhoneBridge's own panes")
        #expect(model.transfers.jobs.isEmpty)

        // Dropped on the Mac pane: one ordinary download of both files.
        let destination = directory.appending(path: "drop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.dropOnLocal(DropLoader.Contents(payloads: payloads), into: destination)
        await model.transfers.waitUntilIdle()
        #expect(model.transfers.jobs.count == 1)
        #expect(model.transfers.jobs.first?.isDragExport == false)
        #expect(model.transfers.jobs.first?.state == .completed)
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false))
        #expect(Set(names) == ["메모.txt", "가계부 2026.xlsx"])
    }

    @Test func droppingOnADeviceFolderMovesTheDraggedItemsIntoIt() async throws {
        let model = try await makeModel()
        try await enter("Documents", in: model)
        let memo = try item("메모.txt", in: model), folder = try item("빈 폴더", in: model)
        let trap = PromiseTrap()
        let pasteboard = dragPasteboard([model.dragPayload(for: memo).encoded()], trap: trap)
        defer { pasteboard.releaseGlobally() }

        model.dropOnDevice(DropLoader.Contents(payloads: DropLoader.inAppPayloads(pasteboard)), onto: folder)
        await model.transfers.waitUntilIdle()
        #expect(trap.askedTypes.isEmpty)
        #expect(model.transfers.jobs.first?.state == .completed)
        let moved = try await model.demoDevice.contents(of: folder.id).map(\.name)
        #expect(moved == ["메모.txt"])
    }

    @Test func dragsFromOtherAppsHaveNoInAppPayload() {
        let trap = PromiseTrap()
        let pasteboard = dragPasteboard(["/Users/someone/file.txt", "phonebridge-drag:not-base64"], trap: trap)
        defer { pasteboard.releaseGlobally() }
        #expect(DropLoader.inAppPayloads(pasteboard).isEmpty)
        #expect(trap.askedTypes.isEmpty)
    }

    @Test func iconViewDragsEverySelectedItem() async throws {
        let model = try await makeModel()
        try await enter("Documents", in: model)
        let memo = try item("메모.txt", in: model), budget = try item("가계부 2026.xlsx", in: model)
        let drags = model.dragItems([memo.id, budget.id])
        #expect(Set(drags.map(\.item.name)) == ["메모.txt", "가계부 2026.xlsx"])
        #expect(drags.allSatisfy { $0.generation == model.browser.generation ?? 0 })
    }
}
