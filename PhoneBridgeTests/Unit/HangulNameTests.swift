import Foundation
import Testing
@testable import PhoneBridge

/// Korean names from macOS are often decomposed (NFD). The device must get
/// precomposed names (NFC), or Android shows separate jamo.
@MainActor
@Suite("Hangul file names (NFC on the device)")
struct HangulNameTests {
    static let nfc = "가족사진 2026.jpg"
    static let nfd = nfc.decomposedStringWithCanonicalMapping

    static func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    @Test func formsDifferInBytesButNotInSwift() {
        #expect(Self.scalars(Self.nfc) != Self.scalars(Self.nfd), "test data really is decomposed")
        #expect(Self.nfc == Self.nfd, "Swift compares by canonical equivalence")
        #expect(Self.scalars(FileNameRules.deviceForm(Self.nfd)) == Self.scalars(Self.nfc))
        #expect(Self.scalars(FileNameRules.sanitizedForDevice(Self.nfd)) == Self.scalars(Self.nfc))
    }

    @Test func lengthLimitsCountTheDeviceForm() {
        // 85 syllables: 255 UTF-8 bytes precomposed, 765 decomposed.
        let long = String(repeating: "한", count: 85)
        let decomposed = long.decomposedStringWithCanonicalMapping
        #expect(decomposed.utf8.count > 255)
        #expect(FileNameRules.validationError(for: decomposed) == nil)
        #expect(FileNameRules.sanitizedForDevice(decomposed).count == 85)
    }

    @Test func mockDeviceStoresPrecomposedNames() async throws {
        let fs = MockDeviceFileSystem()
        let root = FileItemID.root(deviceID: fs.deviceID, storageID: MockDeviceFileSystem.internalStorageID)
        let folder = try await fs.createFolder(named: "여행 사진".decomposedStringWithCanonicalMapping, in: root)
        #expect(Self.scalars(folder.name) == Self.scalars("여행 사진"))
        let renamed = try await fs.rename(folder.id, to: "제주 여행".decomposedStringWithCanonicalMapping)
        #expect(Self.scalars(renamed.name) == Self.scalars("제주 여행"))
    }

    @Test func uploadOfADecomposedMacFileArrivesPrecomposedAndConflictsAreFound() async throws {
        let local = FileManager.default.temporaryDirectory.appending(path: "PBHangul-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appending(path: Self.nfd)
        try Data(repeating: 7, count: 4_096).write(to: source)

        let fs = MockDeviceFileSystem()
        var asked: [TransferConflict] = []
        let manager = TransferManager(fileSystemProvider: { _ in fs }, volume: FakeVolume(available: nil),
                                      scratchDirectory: local.appending(path: ".scratch"))
        manager.conflictResolver = { conflict in
            asked.append(conflict)
            return .always(.skip)
        }
        let root = FileItemID.root(deviceID: fs.deviceID, storageID: MockDeviceFileSystem.internalStorageID)
        let download = try #require(try await fs.contents(of: root).first { $0.name == "Download" })
        let destination = DeviceFolderRef(id: download.id, path: ["Download"])

        manager.enqueue(.upload(sources: [source], destination: destination, generation: fs.generation, removeSourceAfter: false),
                        destinationName: "Download")
        await manager.waitUntilIdle()
        let uploaded = try #require(try await fs.contents(of: download.id).first { $0.name == Self.nfc })
        #expect(Self.scalars(uploaded.name) == Self.scalars(Self.nfc))

        // The same file again: recognised as the same name, not uploaded twice.
        manager.enqueue(.upload(sources: [source], destination: destination, generation: fs.generation, removeSourceAfter: false),
                        destinationName: "Download")
        await manager.waitUntilIdle()
        #expect(asked.count == 1)
        #expect(try await fs.contents(of: download.id).filter { $0.name == Self.nfc }.count == 1)
    }

    @Test func realDevicePathSendsPrecomposedNames() async throws {
        let monitor = MockUSBMonitor()
        let backend = MockMTPBackend()
        let broker = DeviceBroker(monitor: monitor, backend: backend, configuration: .fast)
        broker.start()
        let id = USBDeviceSnapshot.fixture().logicalID
        monitor.send(.attached(.fixture()))
        try await waitUntil { broker.record(for: id)?.state == .connected }
        let fs = try #require(broker.fileSystem(for: id))

        let root = FileItemID.root(deviceID: id, storageID: 0x0001_0001)
        _ = try await fs.createFolder(named: "새 폴더".decomposedStringWithCanonicalMapping, in: root)
        let stored = try #require(backend.object(named: "새 폴더"))
        #expect(Self.scalars(stored.name) == Self.scalars("새 폴더"), "MTP received the precomposed name")
    }
}
