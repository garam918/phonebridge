import Foundation

/// Fixed-size cache that drops the least recently used entry when full.
/// Sized for hundreds of entries (eviction scans the keys).
struct LRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var entries: [Key: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { entries.count }

    /// The value for `key`, marking it as recently used.
    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock += 1
        entries[key] = (entry.value, clock)
        return entry.value
    }

    func contains(_ key: Key) -> Bool { entries[key] != nil }

    mutating func insert(_ value: Value, for key: Key) {
        clock += 1
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = (value, clock)
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
