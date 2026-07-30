import Foundation

/// Resolves raw link targets to documents, using Obsidian's rules.
///
/// Basename-first: `[[Design]]` finds `Projects/Design.md` although the link
/// names neither the folder nor the extension. A target containing a `/`
/// is treated as a path suffix and disambiguates. Matching is case-insensitive,
/// as Obsidian is on macOS. Frontmatter aliases participate.
///
/// Ambiguity is resolved to the SHORTEST path, matching Obsidian — a link can
/// therefore point somewhere the author did not intend when two documents share
/// a basename, which is why the backlinks panel surfaces ambiguity.
///
/// Resolution MUST be a pure function of the vault's contents, independent of
/// the order documents were passed to `init` or of `Dictionary` iteration
/// order (which Swift randomizes per process via hash seeding). Two places
/// need this discipline:
///  - the suffix-match branch of `resolve`, which used to filter
///    `byKey.values.flatMap { $0 }` — iterating a dictionary's `.values` — and
///    could resolve the same link to a different document on different runs
///    of the same, unchanged vault;
///  - the per-key candidate lists in `byKey`, whose equal-length ties used to
///    fall back to `Array.sorted`'s stability, i.e. to input order (which is
///    filesystem enumeration order in `scanVault`, row order in
///    `indexDocument` — neither guaranteed stable across runs).
/// Both are fixed the same way: sort by path length, then lexicographically
/// by the full path, so equal-length ties break on path content alone.
public struct LinkResolver: Sendable {
    private let byKey: [String: [URL]]
    /// All document URLs, sorted deterministically (length then lexicographic
    /// path) — the candidate source for the suffix-match branch. Built once
    /// so a per-call `.values.flatMap` (dictionary iteration order, and
    /// O(total documents) per call) is never needed.
    private let sortedDocuments: [URL]

    public init(documents: [(url: URL, title: String, aliases: [String])]) {
        var map: [String: [URL]] = [:]
        var seen = Set<String>()
        var allURLs: [URL] = []
        for doc in documents {
            if seen.insert(doc.url.path).inserted { allURLs.append(doc.url) }
            var keys = [doc.url.deletingPathExtension().lastPathComponent, doc.title]
            keys.append(contentsOf: doc.aliases)
            for key in keys where !key.isEmpty {
                map[key.lowercased(), default: []].append(doc.url)
            }
        }
        byKey = map.mapValues { Self.sortDeterministically($0) }
        sortedDocuments = Self.sortDeterministically(allURLs)
    }

    /// Shortest path first; equal-length ties broken lexicographically by
    /// the full path — never by insertion or iteration order.
    private static func sortDeterministically(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.path.count != $1.path.count
                ? $0.path.count < $1.path.count
                : $0.path < $1.path
        }
    }

    /// Strips any `#Heading` / `#^block` fragment and a trailing `.md`.
    public static func basename(of rawTarget: String) -> String {
        var target = rawTarget
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        if target.lowercased().hasSuffix(".md") { target = String(target.dropLast(3)) }
        return target.trimmingCharacters(in: .whitespaces)
    }

    public func resolve(_ rawTarget: String) -> URL? {
        let target = Self.basename(of: rawTarget)
        guard !target.isEmpty else { return nil }

        if target.contains("/") {
            // Explicit path: match as a suffix of a document's path.
            // `sortedDocuments` is a deterministic, pre-sorted source, so the
            // first match is also the shortest-then-lexicographic winner —
            // no per-call min() over dictionary-derived order needed.
            let needle = "/" + target.lowercased()
            return sortedDocuments.first {
                $0.deletingPathExtension().path.lowercased().hasSuffix(needle)
            }
        }
        return byKey[target.lowercased()]?.first
    }
}
