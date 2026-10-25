import Foundation
import Testing
@testable import PhoneBridge

@MainActor
@Suite("BrowserViewModel (mock file system)")
struct BrowserViewModelTests {
    let fileSystem = MockDeviceFileSystem()

    private var internalStorage: StorageInfo {
        get async throws { try #require(try await fileSystem.storages().first) }
    }

    private func openedBrowser() async throws -> BrowserViewModel {
        let browser = BrowserViewModel()
        await browser.open(fileSystem, storage: try await internalStorage)
        return browser
    }

    @Test func opensStorageRootSortedWithFoldersFirst() async throws {
        let browser = try await openedBrowser()
        #expect(browser.phase == .loaded)
        #expect(browser.items.map(\.name) == ["Android", "DCIM", "Documents", "Download", "Movies", "Music", "Pictures"])
        #expect(browser.path.map(\.name) == ["내부 저장공간"])
        #expect(browser.currentFolder?.isStorageRoot == true)
        #expect(browser.isShowingMock)
        #expect(!browser.canGoBack && !browser.canGoForward && !browser.canGoUp)
    }

    @Test func navigatesIntoFoldersAndBackForwardUp() async throws {
        let browser = try await openedBrowser()
        let dcim = try #require(browser.items.first { $0.name == "DCIM" })
        await browser.enter(dcim)
        #expect(browser.items.map(\.name) == ["Camera", "Screenshots"])

        let camera = try #require(browser.items.first { $0.name == "Camera" })
        await browser.enter(camera)
        #expect(browser.path.map(\.name) == ["내부 저장공간", "DCIM", "Camera"])
        #expect(browser.items.count == 13)

        await browser.goBack()
        #expect(browser.path.map(\.name) == ["내부 저장공간", "DCIM"])
        #expect(browser.canGoForward)

        await browser.goForward()
        #expect(browser.path.last?.name == "Camera")

        await browser.goUp()
        #expect(browser.path.last?.name == "DCIM")
        #expect(!browser.canGoForward, "a new navigation clears forward history")

        await browser.goToPathIndex(0)
        #expect(browser.path.count == 1)
        #expect(browser.items.first?.name == "Android")
    }

    @Test func selectionExposesSingleItemInfo() async throws {
        let browser = try await openedBrowser()
        let download = try #require(browser.items.first { $0.name == "Download" })
        await browser.enter(download)

        let pdf = try #require(browser.items.first { $0.name.hasSuffix(".pdf") })
        browser.selection = [pdf.id]
        #expect(browser.selectedItem == pdf)
        #expect(browser.selectedItem?.category == .document)
        #expect(browser.selectedItem?.size == 1_204_331)

        browser.selection.insert(browser.items[0].id)
        #expect(browser.selectedItem == nil)
        #expect(browser.selectedItems.count == 2)
    }

    @Test func changingSortReordersItems() async throws {
        let browser = try await openedBrowser()
        let download = try #require(browser.items.first { $0.name == "Download" })
        await browser.enter(download)

        browser.sort = FileSortDescriptor(key: .size, ascending: false, foldersFirst: true)
        #expect(browser.items.first?.name == "app-release.apk")
        browser.sort = FileSortDescriptor(key: .name, ascending: true, foldersFirst: true)
        // Natural ordering: 견적서2 before 견적서10.
        let names = browser.items.map(\.name)
        let two = try #require(names.firstIndex(of: "견적서2.xlsx"))
        let ten = try #require(names.firstIndex(of: "견적서10.xlsx"))
        #expect(two < ten)
    }

    @Test func staleListingNeverOverwritesNewerLocation() async throws {
        let slow = MockDeviceFileSystem(latency: .milliseconds(150))
        let storages = try await slow.storages()
        let browser = BrowserViewModel()
        browser.setRoot(slow, storage: storages[0])
        let first = Task { await browser.reload() }
        try await Task.sleep(for: .milliseconds(20))
        // The user switches to the SD card before the first listing returns.
        await browser.open(slow, storage: storages[1])
        await first.value
        #expect(browser.storage?.id == MockDeviceFileSystem.sdCardStorageID)
        #expect(browser.items.map(\.name) == ["Backup", "DCIM"])
    }

    @Test func missingFolderBecomesFailedPhase() async throws {
        let browser = try await openedBrowser()
        let ghost = FileItem(id: FileItemID(deviceID: .demo, storageID: MockDeviceFileSystem.internalStorageID, objectID: 0xBEEF),
                             name: "ghost", isFolder: true, size: nil, modified: nil)
        await browser.enter(ghost)
        #expect(browser.phase == .failed(.objectNotFound))
        #expect(browser.items.isEmpty)
        await browser.goBack()
        #expect(browser.phase == .loaded)
    }

    @Test func resetClearsEverything() async throws {
        let browser = try await openedBrowser()
        browser.selection = [browser.items[0].id]
        browser.reset()
        #expect(browser.fileSystem == nil)
        #expect(browser.items.isEmpty && browser.path.isEmpty && browser.selection.isEmpty)
        #expect(browser.phase == .idle)
    }
}
