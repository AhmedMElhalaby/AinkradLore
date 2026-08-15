import Foundation

/// Moving between documents: the back/forward trail, and the cache of
/// documents kept warm behind the one on screen.
///
/// Split out of `LoreStore.swift` for the 500-line ceiling. Both halves are
/// here because they are one mechanism seen from two sides — history decides
/// WHERE you go, the warm cache decides whether getting there costs a reload —
/// and together they are what replaced the tab bar.
///
/// The stored properties (`tabs`, `selectedTab`, `history`, `historyIndex`)
/// stay on the type itself, as Swift requires; only the logic moved.
extension LoreStore {

    // `touch`, `evictColdSessions` and `recordVisit` are internal rather than
    // private: `open(url:recordingHistory:)` and `selectTab` call them from
    // `LoreStore.swift`, and Swift's `private` is file-scoped. They remain
    // implementation detail outside the module.

    // MARK: - Warm sessions

    /// How many documents stay loaded in memory at once.
    ///
    /// With the tab strip gone, `tabs` is no longer a list the user reads — it
    /// is a CACHE of documents that are still open behind the one on screen.
    /// Keeping them warm is the decision that makes single-document navigation
    /// safe: following a `[[link]]` never has to flush or close the document
    /// you came from, so it can never hit `closeTab`'s unsaved-work refusal
    /// mid-navigation, and per-document dirty state survives a round trip.
    ///
    /// Eight is a judgement, not a measurement: enough that Back through a
    /// chain of links finds every document still loaded (with its scroll
    /// position and undo stack intact), few enough that a long session does
    /// not accumulate unbounded `DocumentSession`s, each holding a parsed
    /// document and a file watcher's worth of state.
    static let warmSessionLimit = 8

    /// Marks `session` as most-recently-used.
    ///
    /// `tabs` is kept in LRU order — least recent first — which is only
    /// possible now that nothing renders it as a strip. Reordering a visible
    /// tab bar under the user would have been unacceptable; reordering a
    /// cache is invisible.
    func touch(_ session: DocumentSession) {
        guard let index = tabs.firstIndex(where: { $0 === session }) else { return }
        tabs.append(tabs.remove(at: index))
    }

    /// Drops the coldest sessions once over the limit.
    ///
    /// REFUSES to evict anything that would lose work: the selected document,
    /// anything dirty, anything in conflict, and anything whose last save
    /// failed. The limit is therefore a target rather than a guarantee — with
    /// nine dirty documents open, nine stay open. That is the correct trade:
    /// a cache that silently discards unsaved edits to honour a size bound is
    /// the exact class of bug this codebase spends most of its comments
    /// preventing.
    func evictColdSessions() {
        guard tabs.count > Self.warmSessionLimit else { return }
        var overflow = tabs.count - Self.warmSessionLimit
        for session in tabs where overflow > 0 {
            guard session !== selectedTab,
                  !session.isDirty, !session.conflict, session.lastSaveError == nil
            else { continue }
            session.cancelPendingSave()
            tabs.removeAll { $0 === session }
            overflow -= 1
        }
    }
    public var canGoBack: Bool { (historyIndex ?? 0) > 0 }
    public var canGoForward: Bool {
        guard let index = historyIndex else { return false }
        return index + 1 < history.count
    }

    /// Records a visit, truncating any forward entries.
    ///
    /// Truncation is what makes Forward mean something: after going Back and
    /// then opening something new, the trail you abandoned is not somewhere
    /// you can return to — the same rule every browser follows, and the
    /// absence of it is how a forward stack turns into a list of places the
    /// user has no memory of choosing.
    ///
    /// Re-visiting the CURRENT document records nothing: clicking the open
    /// note in the sidebar is not navigation, and treating it as such fills
    /// the stack with duplicates that make Back appear broken.
    func recordVisit(_ url: URL) {
        let key = Self.pathKey(url)
        if let index = historyIndex, history.indices.contains(index),
           Self.pathKey(history[index]) == key {
            return
        }
        if let index = historyIndex, index + 1 < history.count {
            history.removeSubrange((index + 1)...)
        }
        history.append(url)
        historyIndex = history.count - 1
    }

    /// Opens the previously visited document.
    @discardableResult
    public func goBack() -> Bool {
        guard canGoBack, let index = historyIndex else { return false }
        historyIndex = index - 1
        open(url: history[index - 1], recordingHistory: false)
        return true
    }

    @discardableResult
    public func goForward() -> Bool {
        guard canGoForward, let index = historyIndex else { return false }
        historyIndex = index + 1
        open(url: history[index + 1], recordingHistory: false)
        return true
    }
}
