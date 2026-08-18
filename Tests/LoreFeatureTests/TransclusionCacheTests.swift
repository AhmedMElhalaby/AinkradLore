import XCTest
@testable import LoreFeature

@MainActor
final class TransclusionCacheTests: XCTestCase {

    private func key(_ name: String, mtime: TimeInterval = 0,
                     fragment: String? = nil) -> TransclusionKey {
        TransclusionKey(path: URL(fileURLWithPath: "/vault/\(name)"),
                        mtime: Date(timeIntervalSince1970: mtime),
                        fragment: fragment)
    }

    func test_missParses_hitDoesNot() {
        let cache = TransclusionCache()
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md"), make: make)
        _ = cache.content(for: key("a.md"), make: make)
        XCTAssertEqual(made, 1, "a cache hit re-parsed the target")
    }

    func test_mtimeBumpInvalidates() {
        let cache = TransclusionCache()
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md", mtime: 0), make: make)
        _ = cache.content(for: key("a.md", mtime: 1), make: make)
        XCTAssertEqual(made, 2, "an edited target served stale content")
    }

    func test_differentFragmentsOfOneFileAreDistinctEntries() {
        let cache = TransclusionCache()
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md", fragment: "one"), make: make)
        _ = cache.content(for: key("a.md", fragment: "two"), make: make)
        XCTAssertEqual(made, 2)
    }

    func test_invalidatingOnePathLeavesOthersAlone() {
        let cache = TransclusionCache()
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md"), make: make)
        _ = cache.content(for: key("b.md"), make: make)
        cache.invalidate(path: URL(fileURLWithPath: "/vault/a.md"))
        _ = cache.content(for: key("b.md"), make: make)
        XCTAssertEqual(made, 2, "an unrelated watcher event dropped a good entry")
    }
}
