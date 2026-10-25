import Darwin
import Foundation
import Testing
@testable import PhoneBridge

/// Measurements for the release report (docs/PERFORMANCE.md). They run on the
/// mock device, so they measure PhoneBridge's own cost (listing, sorting,
/// staging, verification, memory), not USB or the phone. Bounds are loose
/// regressions guards; the numbers themselves are printed as "PERF …".
@MainActor
@Suite("Performance (mock device)", .serialized)
struct PerformanceTests {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func report(_ name: String, _ value: Double, _ unit: String) {
        print("PERF \(name) = \(String(format: "%.3f", value)) \(unit)")
    }

    /// One folder with `count` photos at the storage root.
    private func bigFolder(_ count: Int) -> MockDeviceFileSystem {
        let storage = MockDeviceFileSystem.internalStorageID
        var nodes = MockDeviceFileSystem.sampleTree()
        nodes.append(.init(objectID: 0x8_0000, storageID: storage, parentID: FileItemID.rootObjectID, name: "Camera10k",
                           isFolder: true, size: nil, modified: Date()))
        for index in 0..<count {
            nodes.append(.init(objectID: 0x9_0000 + UInt32(index), storageID: storage, parentID: 0x8_0000,
                               name: String(format: "IMG_2026%04d_%06d.jpg", index % 1231, index),
                               isFolder: false, size: UInt64(1_500_000 + index * 37), modified: Date(timeIntervalSince1970: 1_790_000_000 + Double(index))))
        }
        return MockDeviceFileSystem(nodes: nodes)
    }

    @Test func tenThousandFileFolderListsSortsAndFilters() async throws {
        let fs = bigFolder(10_000)
        let browser = BrowserViewModel()
        await browser.open(fs, storage: try #require(try await fs.storages().first))
        let folder = try #require(browser.items.first { $0.name == "Camera10k" })
        let clock = ContinuousClock()

        let open = await clock.measure { await browser.enter(folder) }
        #expect(browser.items.count == 10_000)
        let bySize = clock.measure { browser.sort = FileSortDescriptor(key: .size, ascending: false) }
        let byName = clock.measure { browser.sort = FileSortDescriptor(key: .name) }
        browser.searchText = "_0099"
        var hits = 0
        let filter = clock.measure { hits = browser.displayedItems.count }
        browser.searchText = ""
        report("list+sort 10,000 (mock, no USB)", Self.seconds(open) * 1000, "ms")
        report("re-sort 10,000 by size", Self.seconds(bySize) * 1000, "ms")
        report("re-sort 10,000 by name (localized)", Self.seconds(byName) * 1000, "ms")
        report("filter 10,000 by text", Self.seconds(filter) * 1000, "ms")
        #expect(hits > 0)
        #expect(open < .seconds(3) && byName < .seconds(2) && filter < .seconds(1))
    }

    @Test func dragOfTenThousandSelectedItemsIsBuiltQuickly() async throws {
        let defaults = freshDefaults()
        defaults.set(false, forKey: AppSettings.Key.showDemoDevice)
        let fs = bigFolder(10_000)
        let model = AppModel(broker: DeviceBroker(monitor: MockUSBMonitor(), backend: MockMTPBackend()),
                             localization: LocalizationManager(defaults: defaults), settings: AppSettings(defaults: defaults),
                             demoDevice: fs,
                             localAccess: LocalAccessManager(defaults: defaults, defaultFolder: FileManager.default.temporaryDirectory))
        await model.browser.open(fs, storage: try #require(try await fs.storages().first))
        await model.browser.enter(try #require(model.browser.items.first { $0.name == "Camera10k" }))
        model.browser.selection = Set(model.browser.items.map(\.id))

        let clock = ContinuousClock()
        var items: [DeviceDragItem] = []
        // Icon view: one call for the whole selection.
        let container = clock.measure { items = model.dragItems(model.browser.items.map(\.id)) }
        // List view: SwiftUI asks every dragged row for its item.
        let rows = clock.measure { items = model.browser.items.map { model.dragItem(for: $0) } }
        report("drag items for 10,000 selected (icon view)", Self.seconds(container) * 1000, "ms")
        report("drag items for 10,000 selected rows (list view)", Self.seconds(rows) * 1000, "ms")
        #expect(items.count == 10_000)
        #expect(container < .seconds(2) && rows < .seconds(2))
    }

    @Test(.timeLimit(.minutes(3)))
    func oneGiBDownloadPipelineSpeedAndMemory() async throws {
        let size: UInt64 = 1 << 30
        let storage = MockDeviceFileSystem.internalStorageID
        let fs = MockDeviceFileSystem(nodes: MockDeviceFileSystem.sampleTree() + [
            .init(objectID: 0x9000, storageID: storage, parentID: FileItemID.rootObjectID, name: "movie.mp4",
                  isFolder: false, size: size, modified: Date()),
        ], faults: .init(chunkSize: 8 << 20))
        let local = FileManager.default.temporaryDirectory.appending(path: "PBPerf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let manager = TransferManager(fileSystemProvider: { _ in fs }, volume: FakeVolume(available: nil),
                                      scratchDirectory: local.appending(path: ".scratch"))
        let root = FileItemID.root(deviceID: fs.deviceID, storageID: storage)
        let movie = try #require(try await fs.contents(of: root).first { $0.name == "movie.mp4" })

        let before = Self.footprint()
        var peak = before
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                peak = max(peak, Self.footprint())
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            manager.enqueue(.download(items: [DeviceItemRef(item: movie, parentPath: [])], generation: fs.generation,
                                      destination: local, deleteSourceAfter: false), destinationName: "perf")
            await manager.waitUntilIdle()
        }
        sampler.cancel()
        #expect(manager.jobs.first?.state == .completed)
        #expect(LocalFileIO.fileSize(local.appending(path: "movie.mp4")) == size)
        let mbps = Double(size) / 1_048_576 / Self.seconds(elapsed)
        let growth = Double(peak.saturatingSubtract(before)) / 1_048_576
        report("1 GiB download pipeline (mock, no USB)", mbps, "MiB/s")
        report("1 GiB download peak footprint growth", growth, "MiB")
        #expect(growth < 256, "downloads stream; they must not buffer the file")
    }

    @Test func previewCacheStaysWithinItsLimit() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "PBPreviewCache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cache) }
        let fs = MockDeviceFileSystem()
        let previews = PreviewService(cacheDirectory: cache, cacheLimit: 60_000)
        let root = FileItemID.root(deviceID: fs.deviceID, storageID: MockDeviceFileSystem.internalStorageID)
        let download = try #require(try await fs.contents(of: root).first { $0.name == "Download" })
        let files = try await fs.contents(of: download.id).filter { $0.name.hasSuffix(".xlsx") || $0.name.hasSuffix(".pdf") }
            .sorted { ($0.size ?? 0) < ($1.size ?? 0) }
        #expect(files.count >= 3)
        for file in files.prefix(3) {
            await previews.preview(file, in: fs)
            #expect(previews.previewURL?.lastPathComponent == file.name)
        }
        // The newest preview always stays even when it alone exceeds the limit.
        #expect(previews.cacheSize <= max(60_000, files.prefix(3).last?.size ?? 0))
        #expect(FileManager.default.fileExists(atPath: try #require(previews.previewURL).path(percentEncoded: false)))
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}

@Suite("LRU cache")
struct LRUCacheTests {
    @Test func dropsTheLeastRecentlyUsedEntry() {
        var cache = LRUCache<Int, String>(capacity: 3)
        cache.insert("a", for: 1)
        cache.insert("b", for: 2)
        cache.insert("c", for: 3)
        _ = cache.value(for: 1)          // 1 is fresh again; 2 is now the oldest
        cache.insert("d", for: 4)
        #expect(cache.count == 3)
        #expect(cache.contains(1) && cache.contains(3) && cache.contains(4))
        #expect(!cache.contains(2))
        cache.insert("a2", for: 1)       // replacing does not evict
        #expect(cache.count == 3 && cache.value(for: 1) == "a2")
    }

    @Test func scrollingBackKeepsRecentThumbnails() {
        // The old cache emptied itself completely at 300 entries.
        var cache = LRUCache<Int, Int>(capacity: PreviewService.thumbnailCacheSize)
        for index in 0..<1_000 { cache.insert(index, for: index) }
        #expect(cache.count == PreviewService.thumbnailCacheSize)
        #expect(cache.contains(999) && cache.contains(1_000 - PreviewService.thumbnailCacheSize))
        #expect(!cache.contains(0))
    }
}
