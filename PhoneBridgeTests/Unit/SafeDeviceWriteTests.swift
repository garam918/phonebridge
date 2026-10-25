import Foundation
import Testing
@testable import PhoneBridge

/// The shared "never lose the original" rules used by app uploads and Finder writes.
@MainActor
@Suite("SafeDeviceWrite")
struct SafeDeviceWriteTests {
    let fs = MockDeviceFileSystem()
    let journal = DeviceLeftoverJournal(fileURL: nil)

    private func documents() async throws -> (FileItemID, FileItem) {
        let root = FileItemID.root(deviceID: fs.deviceID, storageID: MockDeviceFileSystem.internalStorageID)
        let folder = try #require(try await fs.contents(of: root).first { $0.name == "Documents" })
        let memo = try #require(try await fs.contents(of: folder.id).first { $0.name == "메모.txt" })
        return (folder.id, memo)
    }

    private func source(_ bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pb-safe-\(UUID().uuidString)")
        try Data(repeating: 9, count: bytes).write(to: url)
        return url
    }

    @Test func replaceSwapsAndLeavesNothingHidden() async throws {
        let (folder, memo) = try await documents()
        let url = try source(100)
        defer { try? FileManager.default.removeItem(at: url) }
        let placed = try await SafeDeviceWrite(fileSystem: fs, journal: journal)
            .upload(url, size: 100, named: "메모.txt", into: folder, path: ["Documents"], replacing: memo, modified: nil,
                    progress: TransferProgress())
        #expect(placed.size == 100)
        let names = try await fs.contents(of: folder).map(\.name)
        #expect(names.filter { $0 == "메모.txt" }.count == 1)
        #expect(!names.contains { FileNameRules.isTemporary($0) })
        #expect(journal.entries.isEmpty)
    }

    @Test func failedFinalRenameRestoresTheOriginal() async throws {
        let (folder, memo) = try await documents()
        let url = try source(100)
        defer { try? FileManager.default.removeItem(at: url) }
        // Rename 1 moves the original aside, rename 2 (staging → final) fails.
        fs.configureFaults { $0.failingCall[.rename] = (call: 2, error: .disconnected) }
        var leftovers: [String] = []
        await #expect(throws: DeviceError.disconnected) {
            _ = try await SafeDeviceWrite(fileSystem: fs, journal: journal, onLeftover: { leftovers.append($0) })
                .upload(url, size: 100, named: "메모.txt", into: folder, path: ["Documents"], replacing: memo, modified: nil,
                        progress: TransferProgress())
        }
        let restored = try #require(try await fs.contents(of: folder).first { $0.name == "메모.txt" })
        #expect(restored.size == memo.size, "the original is back")
        #expect(!(try await fs.contents(of: folder)).contains { FileNameRules.isTemporary($0.name) })
        #expect(leftovers.isEmpty && journal.entries.isEmpty)
    }

    @Test func checkpointStopsBeforeAnythingIsReplaced() async throws {
        let (folder, memo) = try await documents()
        let url = try source(100)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: DeviceError.cancelled) {
            _ = try await SafeDeviceWrite(fileSystem: fs, journal: journal, checkpoint: { () throws(DeviceError) in throw .cancelled })
                .upload(url, size: 100, named: "메모.txt", into: folder, path: nil, replacing: memo, modified: nil,
                        progress: TransferProgress())
        }
        let names = try await fs.contents(of: folder).map(\.name)
        #expect(names.contains("메모.txt") && !names.contains { FileNameRules.isTemporary($0) })
        #expect(try await fs.contents(of: folder).first { $0.name == "메모.txt" }?.size == memo.size)
    }
}
