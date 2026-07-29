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
public struct LinkResolver: Sendable {
    private let byKey: [String: [URL]]

    public init(documents: [(url: URL, title: String, aliases: [String])]) {
        var map: [String: [URL]] = [:]
        for doc in documents {
            var keys = [doc.url.deletingPathExtension().lastPathComponent, doc.title]
            keys.append(contentsOf: doc.aliases)
            for key in keys where !key.isEmpty {
                map[key.lowercased(), default: []].append(doc.url)
            }
        }
        // Shortest path wins ties, deterministically.
        byKey = map.mapValues { $0.sorted { $0.path.count < $1.path.count } }
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
            let needle = "/" + target.lowercased()
            let candidates = byKey.values.flatMap { $0 }.filter {
                $0.deletingPathExtension().path.lowercased().hasSuffix(needle)
            }
            return candidates.min { $0.path.count < $1.path.count }
        }
        return byKey[target.lowercased()]?.first
    }
}
