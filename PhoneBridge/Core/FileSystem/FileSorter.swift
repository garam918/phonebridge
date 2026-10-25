import Foundation

enum FileSortKey: String, CaseIterable, Sendable {
    case name, modified, size, kind
}

struct FileSortDescriptor: Equatable, Sendable {
    var key: FileSortKey = .name
    var ascending = true
    var foldersFirst = true
}

/// Anything the sorter can order (device items and Mac items).
protocol FileSortable {
    var name: String { get }
    var isFolder: Bool { get }
    var sizeSortKey: UInt64 { get }
    var modifiedSortKey: Date { get }
    var kindSortKey: String { get }
    var sortTieBreaker: UInt64 { get }
}

extension FileItem: FileSortable {
    var sortTieBreaker: UInt64 { UInt64(id.objectID) }
}

enum FileSorter {
    /// Finder-like ordering: natural name comparison ("사진2" < "사진10"),
    /// folders grouped first, name as the tie breaker for every key.
    static func sorted<Item: FileSortable>(_ items: [Item], by descriptor: FileSortDescriptor) -> [Item] {
        items.sorted { lhs, rhs in
            if descriptor.foldersFirst, lhs.isFolder != rhs.isFolder {
                return lhs.isFolder
            }
            let order = compare(lhs, rhs, key: descriptor.key)
            if order != .orderedSame {
                return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.sortTieBreaker < rhs.sortTieBreaker
        }
    }

    private static func compare<Item: FileSortable>(_ lhs: Item, _ rhs: Item, key: FileSortKey) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .modified:
            return compareValues(lhs.modifiedSortKey, rhs.modifiedSortKey)
        case .size:
            return compareValues(lhs.sizeSortKey, rhs.sizeSortKey)
        case .kind:
            return compareValues(lhs.kindSortKey, rhs.kindSortKey)
        }
    }

    private static func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }
}
