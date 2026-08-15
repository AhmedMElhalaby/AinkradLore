import Foundation

/// Pinned and recently-opened documents — the sidebar's answer to "the five
/// notes I am actually working on".
///
/// ## Why a vault needs this
///
/// Browsing a 17,000-object vault by folder is fine for finding something you
/// remember filing and useless for returning to what you touched an hour ago.
/// Search answers "where is X" and the tree answers "what is in Y"; neither
/// answers "what am I on this week", which for most people is a set of about
/// five documents that changes slowly.
///
/// ## Stored as paths, resolved against the live index
///
/// Both lists hold vault-relative paths, and both are filtered through
/// `store.rows` before display. That is what keeps them honest across renames,
/// moves and deletes: a stale entry simply stops resolving and disappears,
/// rather than sitting in the sidebar as a row that errors when clicked. It
/// also means neither list needs updating when a file moves — the next render
/// just fails to resolve the old path.
///
/// The cost is that a RENAMED document falls out of recents rather than
/// following its new name. That is the right trade for a list this size: the
/// alternative is another consumer of the rename plan, and a rename already
/// rewrites links across the whole vault without having to also patch a
/// preferences blob.
extension LoreStore {

    static let pinnedKey = "pinnedDocuments"
    static let recentsKey = "recentDocuments"

    /// How many recents to keep.
    ///
    /// Ten, not fifty: this is a shortcut list, and a shortcut list long enough
    /// to need scrolling has become a second file browser — one ordered by
    /// something the user cannot see.
    static let recentsLimit = 10

    // MARK: - Pinned

    public func isPinned(_ url: URL) -> Bool {
        pinnedPaths.contains(Self.pathKey(url))
    }

    public func togglePinned(_ url: URL) {
        let key = Self.pathKey(url)
        if pinnedPaths.contains(key) {
            pinnedPaths.remove(key)
        } else {
            pinnedPaths.insert(key)
        }
        persistPinned()
    }

    /// Pinned documents that still exist, in title order.
    ///
    /// Sorted by TITLE rather than by pin order: pinning is a set, not a
    /// sequence, and remembering the order someone pinned things in implies a
    /// meaning the UI never offered a way to change.
    public var pinnedRows: [IndexRow] {
        rows.filter { pinnedPaths.contains(Self.pathKey($0.path)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func persistPinned() {
        documents.setData(pinnedPaths.sorted().joined(separator: "\n").data(using: .utf8),
                          forKey: Self.pinnedKey)
    }

    // MARK: - Recents

    /// Records a visit. Called from `open`, alongside the history stack.
    func noteRecentlyOpened(_ url: URL) {
        let key = Self.pathKey(url)
        recentPaths.removeAll { $0 == key }
        recentPaths.insert(key, at: 0)
        if recentPaths.count > Self.recentsLimit {
            recentPaths.removeSubrange(Self.recentsLimit...)
        }
        documents.setData(recentPaths.joined(separator: "\n").data(using: .utf8),
                          forKey: Self.recentsKey)
    }

    /// Recently opened documents that still exist, most recent first.
    ///
    /// Excludes anything pinned: a document in both lists would occupy two
    /// rows in a sidebar section whose whole purpose is to be short.
    public var recentRows: [IndexRow] {
        let byPath = Dictionary(rows.map { (Self.pathKey($0.path), $0) },
                                uniquingKeysWith: { first, _ in first })
        return recentPaths.compactMap { key in
            pinnedPaths.contains(key) ? nil : byPath[key]
        }
    }

    /// Decodes both lists at startup.
    func loadShortcutLists() {
        if let data = documents.data(forKey: Self.pinnedKey),
           let text = String(data: data, encoding: .utf8) {
            pinnedPaths = Set(text.split(separator: "\n").map(String.init))
        }
        if let data = documents.data(forKey: Self.recentsKey),
           let text = String(data: data, encoding: .utf8) {
            recentPaths = text.split(separator: "\n").map(String.init)
        }
    }
}
