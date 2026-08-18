import Foundation

/// Identifies one cached embed target: the file it came from, that file's
/// mtime at the time it was read, and the fragment (heading/block) sliced
/// out of it, if any. Two different fragments of the same file are distinct
/// entries; a bumped mtime makes an old entry unreachable by key, so the
/// cache never has to actively scan for staleness.
public struct TransclusionKey: Hashable, Sendable {
    public let path: URL
    public let mtime: Date
    public let fragment: String?

    public init(path: URL, mtime: Date, fragment: String?) {
        self.path = path
        self.mtime = mtime
        self.fragment = fragment
    }
}

/// Counts embed measurements. Declared here so the cache and the eventual
/// measurement site (Task 5) share one counter type; `record()` is called
/// from exactly one place, added in Task 5 — not from this file.
@MainActor
public enum TransclusionMeasureCounter {
    public static private(set) var count = 0

    public static func reset() {
        count = 0
    }

    public static func record() {
        count += 1
    }
}

/// An LRU cache of resolved embed content, keyed by `TransclusionKey`.
///
/// Two independent things are cached per entry: the parsed `TransclusionContent`
/// (expensive: a full re-parse of the target note) and an optional measured
/// height (expensive in a different way: a full second layout pass, added by
/// Task 5). They're stored together in one `Entry` rather than two parallel
/// caches, because they always share a key and a lifetime — a `mtime` bump
/// invalidates both, a path invalidation drops both. Only the *measurement*
/// half needs its own narrower invalidation (`invalidateMeasurements()`),
/// which the measure-width and theme-change triggers use because they never
/// change what a target's content is, only how tall it renders.
@MainActor
public final class TransclusionCache {
    private struct Entry {
        var content: TransclusionContent
        var measuredHeight: CGFloat?
    }

    private let capacity: Int
    private var storage: [TransclusionKey: Entry] = [:]
    /// Most-recently-used keys, back to front (front = least recently used).
    private var order: [TransclusionKey] = []

    public init(capacity: Int = 32) {
        self.capacity = capacity
    }

    /// Returns the cached content for `key`, computing and storing it via
    /// `make()` on a miss. A hit never calls `make`.
    public func content(for key: TransclusionKey, make: () -> TransclusionContent) -> TransclusionContent {
        if let entry = storage[key] {
            touch(key)
            return entry.content
        }
        let content = make()
        storage[key] = Entry(content: content, measuredHeight: nil)
        touch(key)
        evictIfNeeded()
        return content
    }

    /// Drops every entry whose key's `path` matches `path`, regardless of
    /// mtime or fragment — used when a file watcher reports a change but the
    /// exact new mtime isn't known to the caller yet.
    public func invalidate(path: URL) {
        let staleKeys = storage.keys.filter { $0.path == path }
        for key in staleKeys {
            storage.removeValue(forKey: key)
        }
        order.removeAll { staleKeys.contains($0) }
    }

    /// Drops measured heights only, keeping parsed content. Serves the
    /// measure-width and theme-change triggers, which change how tall an
    /// embed renders but never what its content is — so re-parsing on those
    /// triggers would be pure waste.
    public func invalidateMeasurements() {
        for key in storage.keys {
            storage[key]?.measuredHeight = nil
        }
    }

    private func touch(_ key: TransclusionKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while storage.count > capacity, !order.isEmpty {
            let lruKey = order.removeFirst()
            storage.removeValue(forKey: lruKey)
        }
    }
}
