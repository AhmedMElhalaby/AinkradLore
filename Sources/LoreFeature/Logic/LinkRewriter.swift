import Foundation

/// One link edit inside one file.
public struct LinkEdit: Sendable, Equatable {
    public let file: URL
    public let oldTarget: String
    public let newTarget: String
    public init(file: URL, oldTarget: String, newTarget: String) {
        self.file = file; self.oldTarget = oldTarget; self.newTarget = newTarget
    }
}

/// The complete change set for a rename or move, computed before anything is
/// written. Nothing in M1 mutates more than one file without one of these.
public struct RenamePlan: Sendable {
    public let source: URL
    public let destination: URL
    public let edits: [LinkEdit]

    public init(source: URL, destination: URL, edits: [LinkEdit]) {
        self.source = source; self.destination = destination; self.edits = edits
    }

    /// First-seen order, deduplicated, so the confirmation UI shows a stable
    /// file list rather than one entry per edit.
    public var affectedFiles: [URL] {
        var seen = Set<String>()
        return edits.compactMap { seen.insert($0.file.path).inserted ? $0.file : nil }
    }
    public var isEmpty: Bool { edits.isEmpty }
}

/// Computes — but never applies — every inbound-link edit a rename or move
/// requires. Pure computation: no disk access, no store, nothing mutated.
/// Task 7 owns applying the resulting `RenamePlan`.
public enum LinkRewriter {
    /// Computes every inbound-link edit a rename or move requires.
    ///
    /// The rewritten target preserves the AUTHOR'S style: a bare `[[Design]]`
    /// becomes `[[Architecture]]`, a foldered `[[Projects/Design]]` keeps its
    /// folder, an extensioned `[[Design.md]]` keeps its extension, and any
    /// `#fragment` survives untouched. Normalizing every link to a full path
    /// would be a bulk mutation nobody asked for.
    ///
    /// An explicit-path target (one containing `/`) is rewritten relative to
    /// `vaultRoot`, since Obsidian's explicit paths are vault-relative, not
    /// relative to the linking document.
    ///
    /// No edit is produced when the rewritten target equals the original —
    /// an unchanged link is not an edit, and listing it would inflate the
    /// count shown in the confirmation UI. This is also why a plain move
    /// (same basename, new folder) produces no edit for a bare link: a bare
    /// link resolves by basename, so it still resolves after the move.
    public static func plan(renaming source: URL,
                            to destination: URL,
                            inboundLinks: [(sourceFile: URL, rawTarget: String)],
                            vaultRoot: URL) -> RenamePlan {
        let edits = inboundLinks.compactMap { link -> LinkEdit? in
            guard let newTarget = rewritten(link.rawTarget, from: source,
                                            to: destination, vaultRoot: vaultRoot),
                  newTarget != link.rawTarget else { return nil }
            return LinkEdit(file: link.sourceFile, oldTarget: link.rawTarget,
                             newTarget: newTarget)
        }
        return RenamePlan(source: source, destination: destination, edits: edits)
    }

    /// Rewrites a single raw link target, or returns `nil` if the target does
    /// not refer to `source` at all.
    static func rewritten(_ rawTarget: String, from source: URL, to destination: URL,
                          vaultRoot: URL) -> String? {
        // Split off the fragment; it is carried through untouched.
        var body = rawTarget
        var fragment = ""
        if let hash = rawTarget.firstIndex(of: "#") {
            body = String(rawTarget[..<hash])
            fragment = String(rawTarget[hash...])
        }
        let hadExtension = body.lowercased().hasSuffix(".md")
        let withoutExtension = hadExtension ? String(body.dropLast(3)) : body
        let hadPath = withoutExtension.contains("/")

        let newBase = destination.deletingPathExtension().lastPathComponent
        var newBody: String
        if hadPath || hadExtension {
            // An explicit path, or an explicit extension, names a location
            // precisely enough that it must track a move — recompute it
            // against the vault root rather than only swapping the basename.
            newBody = destination.deletingPathExtension().path
                .replacingOccurrences(of: vaultRoot.path + "/", with: "")
        } else {
            newBody = newBase
        }
        if hadExtension { newBody += ".md" }
        return newBody + fragment
    }
}
