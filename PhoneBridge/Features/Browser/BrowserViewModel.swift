import Foundation
import Observation

enum SearchScope: String, CaseIterable, Sendable {
    case currentFolder, subfolders
}

struct PathComponent: Hashable, Sendable {
    let folder: FileItemID
    let name: String
}

/// Folder navigation, listing, sorting and selection for one storage.
/// Talks only to `DeviceFileSystem`; results from an outdated request are
/// dropped, so a slow listing can never overwrite a newer location.
@MainActor
@Observable
final class BrowserViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(DeviceError)
    }

    private(set) var fileSystem: (any DeviceFileSystem)?
    private(set) var storage: StorageInfo?
    private(set) var path: [PathComponent] = []
    private(set) var items: [FileItem] = [] {
        didSet { listingVersion &+= 1 }
    }
    /// Changes whenever the listing or search hits change (drag payload cache).
    @ObservationIgnored private(set) var listingVersion = 0
    private(set) var phase: Phase = .idle
    private(set) var backStack: [[PathComponent]] = []
    private(set) var forwardStack: [[PathComponent]] = []
    var selection: Set<FileItemID> = []
    var sort = FileSortDescriptor() {
        didSet {
            if sort != oldValue {
                items = FileSorter.sorted(items, by: sort)
                searchResults = FileSorter.sorted(searchResults, by: sort)
            }
        }
    }

    /// Filters the listing; with `.subfolders` it searches recursively.
    var searchText = "" {
        didSet { if searchText != oldValue { searchChanged() } }
    }
    var searchScope: SearchScope = .currentFolder {
        didSet { if searchScope != oldValue { searchChanged() } }
    }
    private(set) var searchResults: [FileItem] = [] {
        didSet { listingVersion &+= 1 }
    }
    private(set) var isSearching = false
    /// Ancestors (below the storage root) of recursive search hits.
    @ObservationIgnored private var searchAncestors: [FileItemID: [PathComponent]] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    static let searchResultLimit = 2_000

    @ObservationIgnored private var loadToken: UInt64 = 0

    var deviceID: DeviceID? { fileSystem?.deviceID }
    var generation: UInt64? { fileSystem?.generation }
    var isShowingMock: Bool { fileSystem?.isMock ?? false }
    var currentFolder: FileItemID? { path.last?.folder }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { path.count > 1 }

    var isRecursiveSearchActive: Bool { searchScope == .subfolders && !trimmedSearch.isEmpty }

    /// What the list/grid shows: the folder, filtered, or search hits.
    var displayedItems: [FileItem] {
        let query = trimmedSearch
        guard !query.isEmpty else { return items }
        if searchScope == .subfolders { return searchResults }
        return items.filter { $0.name.localizedStandardContains(query) }
    }

    var selectedItems: [FileItem] { displayedItems.filter { selection.contains($0.id) } }
    var selectedItem: FileItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return displayedItems.first { $0.id == id }
    }

    /// Names from the storage root to the current folder.
    var currentPathNames: [String] { path.dropFirst().map(\.name) }

    var currentFolderRef: DeviceFolderRef? {
        currentFolder.map { DeviceFolderRef(id: $0, path: currentPathNames) }
    }

    /// Names from the storage root to the folder containing `item`.
    func parentPathNames(of item: FileItem) -> [String] {
        if let ancestors = searchAncestors[item.id] { return currentPathNames + ancestors.map(\.name) }
        return currentPathNames
    }

    func reference(for item: FileItem) -> DeviceItemRef {
        DeviceItemRef(item: item, parentPath: parentPathNames(of: item))
    }

    /// Location text for a search hit ("DCIM › Camera").
    func locationDescription(of item: FileItem) -> String {
        (path.map(\.name) + (searchAncestors[item.id]?.map(\.name) ?? [])).joined(separator: " › ")
    }

    private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Location

    /// Points the browser at the root of `storage` without loading.
    func setRoot(_ fileSystem: any DeviceFileSystem, storage: StorageInfo) {
        clearSearch()
        loadToken &+= 1
        self.fileSystem = fileSystem
        self.storage = storage
        backStack = []
        forwardStack = []
        path = [PathComponent(folder: .root(deviceID: fileSystem.deviceID, storageID: storage.id), name: storage.name)]
        items = []
        selection = []
        phase = .idle
    }

    func open(_ fileSystem: any DeviceFileSystem, storage: StorageInfo) async {
        setRoot(fileSystem, storage: storage)
        await reload()
    }

    /// Clears everything, e.g. when the device disappeared.
    func reset() {
        clearSearch()
        loadToken &+= 1
        fileSystem = nil
        storage = nil
        path = []
        items = []
        selection = []
        backStack = []
        forwardStack = []
        phase = .idle
    }

    // MARK: - Navigation

    func enter(_ item: FileItem) async {
        guard item.isFolder, fileSystem != nil else { return }
        let ancestors = searchAncestors[item.id] ?? []
        clearSearch()
        await navigate(to: path + ancestors + [PathComponent(folder: item.id, name: item.name)], recordHistory: true)
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchAncestors = [:]
        searchResults = []
        isSearching = false
        if !searchText.isEmpty { searchText = "" }
    }

    private func searchChanged() {
        searchTask?.cancel()
        searchAncestors = [:]
        searchResults = []
        isSearching = false
        selection = []
        guard isRecursiveSearchActive, let fileSystem, let start = currentFolder else { return }
        let query = trimmedSearch
        let sort = sort
        isSearching = true
        searchTask = Task { [weak self] in
            // Debounce typing; MTP listings are slow.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            var results: [FileItem] = []
            var ancestors: [FileItemID: [PathComponent]] = [:]
            var pending: [(FileItemID, [PathComponent])] = [(start, [])]
            while let (folder, trail) = pending.popLast(), results.count < Self.searchResultLimit {
                guard !Task.isCancelled else { return }
                guard let children = try? await fileSystem.contents(of: folder) else { continue }
                for child in children where !FileNameRules.isTemporary(child.name) {
                    if child.name.localizedStandardContains(query) {
                        results.append(child)
                        ancestors[child.id] = trail
                    }
                    if child.isFolder {
                        pending.append((child.id, trail + [PathComponent(folder: child.id, name: child.name)]))
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.searchAncestors = ancestors
                self.searchResults = FileSorter.sorted(results, by: sort)
            }
            self?.isSearching = false
        }
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        await navigate(to: previous, recordHistory: false)
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        await navigate(to: next, recordHistory: false)
    }

    func goUp() async {
        guard canGoUp else { return }
        await navigate(to: Array(path.dropLast()), recordHistory: true)
    }

    func goToPathIndex(_ index: Int) async {
        guard index >= 0, index < path.count - 1 else { return }
        await navigate(to: Array(path.prefix(index + 1)), recordHistory: true)
    }

    func reload() async {
        guard let fileSystem, let folder = currentFolder else { return }
        loadToken &+= 1
        let token = loadToken
        phase = .loading
        do throws(DeviceError) {
            let result = try await fileSystem.contents(of: folder)
            guard token == loadToken else { return }
            items = FileSorter.sorted(result, by: sort)
            selection = selection.intersection(Set(items.map(\.id)))
            phase = .loaded
        } catch {
            guard token == loadToken else { return }
            Log.browser.error("listing \(folder.deviceID, privacy: .private(mask: .hash))/\(folder.storageID)/\(folder.objectID) failed: \(error.localizationKey, privacy: .public)")
            items = []
            selection = []
            phase = .failed(error)
        }
    }

    private func navigate(to newPath: [PathComponent], recordHistory: Bool) async {
        clearSearch()
        if recordHistory, !path.isEmpty {
            backStack.append(path)
            forwardStack.removeAll()
        }
        path = newPath
        items = []
        selection = []
        await reload()
    }
}
