import XCTest
@testable import LoreFeature

extension XCTestCase {

    /// Resets the parse counter AFTER letting in-flight parses land.
    ///
    /// ## The flake this removes
    ///
    /// `MarkdownParseCounter` is process-global, and `applyStyles()` schedules
    /// its parse OFF the main actor. So an earlier test in the same class can
    /// still have a parse in flight when the next one calls `reset()` — the
    /// stray increment lands a moment later and the next assertion reads 1
    /// where it demands 0.
    ///
    /// It is intermittent by construction (it depends on whether the
    /// background parse beats the next test's assertion), which is the worst
    /// property a test can have: these are the guards protecting the main
    /// actor from parsing, and a guard that fails at random is one people
    /// learn to re-run instead of read.
    ///
    /// ## Why draining rather than isolating the counter
    ///
    /// Per-thread counting was the obvious fix and is wrong: several tests
    /// assert `count == 1` for a parse that deliberately happened OFF the main
    /// actor, and a thread-local counter reads 0 for exactly those. The
    /// counter has to stay global, so the fix is to make the reset mean "from
    /// here", which requires no work to still be outstanding.
    ///
    /// Spins the run loop rather than sleeping: the pending work is dispatched
    /// back to the main queue, so a `sleep` would block the very thread that
    /// has to run it and drain nothing at all.
    func resetParseCounter(drainFor interval: TimeInterval = 0.35) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        MarkdownParseCounter.reset()
    }
}
