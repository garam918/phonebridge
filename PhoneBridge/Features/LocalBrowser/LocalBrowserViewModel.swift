import Foundation
import Observation

struct LocalItem: Identifiable, Hashable, Sendable, FileSortable {
    let url: URL
    let name: String
    let isFolder: Bool
    let size: UInt64?
    let modified: Date?

    var id: URL { url }
    var category: FileCategory { isFolder ? .folder : FileCategory(fileName: name) }
    var sizeSortKey: UInt64 { isFolder ? 0 : (size ?? 0) }
    var modifiedSortKey: Date { modified ?? .distantPast }
    var kindSortKey: String { category.rawValue }
    var sortTieBreaker: UInt64 { 0 }
}

/// Mac side of the two-pane mode. Browses inside a folder the user granted
/// (sandbox), never above it.
@MainActor
@Observable
final class LocalBrowserViewModel {
    private(set) var rootURL: URL?
    private(set) var currentURL: URL?
    private(set) var items: [LocalItem] = []
    private(set) var error: DeviceError?
    private(set) var isLoading = false
    var selection: Set<URL> = []
    var sort = FileSortDescriptor() {
        didSet { if sort != oldValue { items = FileSorter.sorted(items, by: sort) } }
    }

    @ObservationIgnored private var loadToken: UInt64 = 0

    var canGoUp: Bool {
        guard let rootURL, let currentURL else { return false }
        return currentURL.standardizedFileURL.path != rootURL.standardizedFileURL.path
    }

    var selectedItems: [LocalItem] { items.filter { selection.contains($0.url) } }

    var pathComponents: [URL] {
        guard let rootURL, let currentURL else { return [] }
        var result: [URL] = [currentURL]
        var cursor = currentURL
        while cursor.standardizedFileURL.path != rootURL.standardizedFileURL.path, cursor.pathComponents.count > 1 {
            cursor = cursor.deletingLastPathComponent()
            result.insert(cursor, at: 0)
        }
        return result
    }

    func open(root: URL) async {
        rootURL = root
        await navigate(to: root)
    }

    func enter(_ item: LocalItem) async {
        guard item.isFolder else { return }
        await navigate(to: item.url)
    }

    func goUp() async {
        guard canGoUp, let currentURL else { return }
        await navigate(to: currentURL.deletingLastPathComponent())
    }

    func navigate(to url: URL) async {
        currentURL = url
        selection = []
        await reload()
    }

    func reload() async {
        guard let currentURL else { return }
        loadToken &+= 1
        let token = loadToken
        isLoading = true
        let result = await Task.detached { Self.list(currentURL) }.value
        guard token == loadToken else { return }
        isLoading = false
        switch result {
        case .success(let list):
            items = FileSorter.sorted(list, by: sort)
            error = nil
            selection = selection.intersection(Set(items.map(\.url)))
        case .failure(let failure):
            items = []
            error = failure
        }
    }

    nonisolated private static func list(_ url: URL) -> Result<[LocalItem], DeviceError> {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])
            return .success(urls.compactMap { child in
                guard let values = try? child.resourceValues(forKeys: Set(keys)),
                      !FileNameRules.isTemporary(child.lastPathComponent) else { return nil }
                let isFolder = values.isDirectory == true
                return LocalItem(url: child, name: child.lastPathComponent, isFolder: isFolder,
                                 size: isFolder ? nil : values.fileSize.map { UInt64(max(0, $0)) },
                                 modified: values.contentModificationDate)
            })
        } catch {
            return .failure(TransferManager.mapLocal(error, url: url, writing: false))
        }
    }
}

/// Remembers folders the user picked (security-scoped bookmarks) so the
/// sandboxed app can reopen them on the next launch. ~/Downloads is always
/// available through the Downloads entitlement.
@MainActor
final class LocalAccessManager {
    private static let bookmarkKey = "local.lastFolderBookmark"
    private let defaults: UserDefaults
    private var accessed: [URL] = []
    let defaultFolder: URL

    init(defaults: UserDefaults = .standard, defaultFolder: URL = UserFolders.downloads) {
        self.defaults = defaults
        self.defaultFolder = defaultFolder
    }

    /// Keeps access to a user-chosen folder for this session and next launch.
    func remember(_ url: URL) {
        if url.startAccessingSecurityScopedResource() { accessed.append(url) }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: Self.bookmarkKey)
        } catch {
            Log.app.error("bookmark failed for \(url.path, privacy: .private): \(error.publicSummary, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    func restoreLastFolder() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            defaults.removeObject(forKey: Self.bookmarkKey)
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        accessed.append(url)
        if stale { remember(url) }
        return url
    }

    func stopAll() {
        accessed.forEach { $0.stopAccessingSecurityScopedResource() }
        accessed.removeAll()
    }
}
