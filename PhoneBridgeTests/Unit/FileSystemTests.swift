import Foundation
import Testing
@testable import PhoneBridge

@Suite("MockDeviceFileSystem")
struct MockDeviceFileSystemTests {
    let fileSystem = MockDeviceFileSystem()

    @Test func exposesTwoStorages() async throws {
        let storages = try await fileSystem.storages()
        #expect(storages.map(\.id) == [MockDeviceFileSystem.internalStorageID, MockDeviceFileSystem.sdCardStorageID])
        #expect(storages.map(\.kind) == [.internalStorage, .removable])
        // Unwrapped first: comparing an Optional<UInt64> inside #expect trips a
        // stack-buffer-overflow report under AddressSanitizer (Swift Testing thunk).
        let used = try #require(storages[0].usedSpace)
        #expect(used == 256_000_000_000 - 98_400_000_000)
        #expect(fileSystem.isMock)
    }

    @Test func listsNestedFolders() async throws {
        let root = try await fileSystem.contents(of: .root(deviceID: .demo, storageID: MockDeviceFileSystem.internalStorageID))
        let dcim = try #require(root.first { $0.name == "DCIM" })
        #expect(dcim.isFolder)
        let dcimChildren = try await fileSystem.contents(of: dcim.id)
        let camera = try #require(dcimChildren.first { $0.name == "Camera" })
        let photos = try await fileSystem.contents(of: camera.id)
        #expect(photos.count == 13)
        #expect(photos.allSatisfy { !$0.isFolder && $0.size != nil && $0.modified != nil })
        #expect(photos.allSatisfy { $0.id.storageID == MockDeviceFileSystem.internalStorageID && $0.id.deviceID == .demo })
    }

    @Test func emptyFolderHasNoChildren() async throws {
        let root = try await fileSystem.contents(of: .root(deviceID: .demo, storageID: MockDeviceFileSystem.internalStorageID))
        let movies = try #require(root.first { $0.name == "Movies" })
        #expect(try await fileSystem.contents(of: movies.id).isEmpty)
    }

    @Test func unknownIDsThrowObjectNotFound() async {
        await #expect(throws: DeviceError.objectNotFound) {
            _ = try await fileSystem.contents(of: FileItemID(deviceID: .demo, storageID: MockDeviceFileSystem.internalStorageID, objectID: 0x1))
        }
        await #expect(throws: DeviceError.objectNotFound) {
            _ = try await fileSystem.contents(of: .root(deviceID: .demo, storageID: 0x9999_0001))
        }
        await #expect(throws: DeviceError.objectNotFound) {
            _ = try await fileSystem.contents(of: .root(deviceID: DeviceID("other"), storageID: MockDeviceFileSystem.internalStorageID))
        }
    }

    @Test func objectIDsAreScopedByStorage() async throws {
        let sdRoot = try await fileSystem.contents(of: .root(deviceID: .demo, storageID: MockDeviceFileSystem.sdCardStorageID))
        let internalRoot = try await fileSystem.contents(of: .root(deviceID: .demo, storageID: MockDeviceFileSystem.internalStorageID))
        #expect(Set(sdRoot.map(\.id)).isDisjoint(with: Set(internalRoot.map(\.id))))
        #expect(sdRoot.map(\.name).sorted() == ["Backup", "DCIM"])
    }
}

@Suite("FileSorter")
struct FileSorterTests {
    private func item(_ id: UInt32, _ name: String, folder: Bool = false, size: UInt64? = nil, day: Int? = nil) -> FileItem {
        FileItem(id: FileItemID(deviceID: .demo, storageID: 1, objectID: id), name: name, isFolder: folder,
                 size: size, modified: day.map { Date(timeIntervalSince1970: TimeInterval($0 * 86_400)) })
    }

    @Test func naturalNameOrderingIncludingHangul() {
        let items = [item(1, "사진10.jpg"), item(2, "사진2.jpg"), item(3, "사진1.jpg"), item(4, "가.txt"), item(5, "Zeta.txt")]
        let names = FileSorter.sorted(items, by: FileSortDescriptor()).map(\.name)
        #expect(names.firstIndex(of: "사진1.jpg")! < names.firstIndex(of: "사진2.jpg")!)
        #expect(names.firstIndex(of: "사진2.jpg")! < names.firstIndex(of: "사진10.jpg")!)
    }

    @Test func foldersFirstThenFiles() {
        let items = [item(1, "b.txt"), item(2, "Z", folder: true), item(3, "a.txt"), item(4, "A", folder: true)]
        #expect(FileSorter.sorted(items, by: FileSortDescriptor()).map(\.name) == ["A", "Z", "a.txt", "b.txt"])
        let mixed = FileSortDescriptor(key: .name, ascending: true, foldersFirst: false)
        #expect(FileSorter.sorted(items, by: mixed).map(\.name) == ["A", "a.txt", "b.txt", "Z"])
    }

    @Test func sortsBySizeAndDateBothDirections() {
        let items = [item(1, "small", size: 10, day: 3), item(2, "big", size: 1_000, day: 1), item(3, "mid", size: 100, day: 2),
                     item(4, "unknown", size: nil, day: nil)]
        #expect(FileSorter.sorted(items, by: .init(key: .size, ascending: false)).map(\.name) == ["big", "mid", "small", "unknown"])
        #expect(FileSorter.sorted(items, by: .init(key: .modified, ascending: true)).map(\.name) == ["unknown", "big", "mid", "small"])
        #expect(FileSorter.sorted(items, by: .init(key: .modified, ascending: false)).first?.name == "small")
    }

    @Test func sortsByKindWithNameTieBreak() {
        let items = [item(1, "b.mp3"), item(2, "a.jpg"), item(3, "c.jpg"), item(4, "doc.pdf")]
        let names = FileSorter.sorted(items, by: .init(key: .kind)).map(\.name)
        #expect(names == ["b.mp3", "doc.pdf", "a.jpg", "c.jpg"]) // audio < document < image
    }

    @Test func tableComparatorMapsToDescriptor() {
        let size = [KeyPathComparator(\FileItem.sizeSortKey, order: .reverse)]
        let descriptor = FileListView.descriptor(from: size, current: FileSortDescriptor())
        #expect(descriptor.key == .size && descriptor.ascending == false && descriptor.foldersFirst)
    }
}
