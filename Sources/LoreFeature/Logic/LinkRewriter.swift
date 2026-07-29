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

/// An inbound link the planner could not rewrite. Surfaced rather than
/// dropped: "the index says this file links here, and the rename cannot fix
/// it" is exactly the condition that, swallowed, produces a rename that looks
/// clean while a link quietly breaks.
public struct UnrewritableLink: Sendable, Equatable {
    public let sourceFile: URL
    public let rawTarget: String
    public init(sourceFile: URL, rawTarget: String) {
        self.sourceFile = sourceFile; self.rawTarget = rawTarget
    }
}

/// The complete change set for a rename or move, computed before anything is
/// written. Nothing in M1 mutates more than one file without one of these.
public struct RenamePlan: Sendable {
    public let source: URL
    public let destination: URL
    public let edits: [LinkEdit]
    /// Links the planner had to give up on — reported by `apply` as failures.
    public let unrewritable: [UnrewritableLink]

    /// Each affected file's modification date AS OF PLANNING TIME, keyed by
    /// path. `apply` refuses to write a file whose mtime has moved past its
    /// entry: with Obsidian open on the same vault, that is an edit made
    /// between the preview and the confirmation, and overwriting it destroys
    /// it. Empty means "no baseline known", which is treated as unsafe-to-
    /// compare rather than safe-to-write — see `LinkRewriter.applyEdits`.
    ///
    /// Captured in `LoreStore.plan`, NOT here: `LinkRewriter` stays pure.
    /// Reading the mtime inside `apply` instead would make the check
    /// tautological (the value is read microseconds before it is compared) and
    /// the guard would never fire.
    public let baselines: [String: Date]

    public init(source: URL, destination: URL, edits: [LinkEdit],
                unrewritable: [UnrewritableLink] = [],
                baselines: [String: Date] = [:]) {
        self.source = source; self.destination = destination; self.edits = edits
        self.unrewritable = unrewritable; self.baselines = baselines
    }

    /// A copy carrying freshly-read mtimes. Keeps the mtime read (I/O) out of
    /// `LinkRewriter` while keeping the value on the plan, where `apply` needs
    /// it and where the preview UI (Task 10) can see it too.
    public func withBaselines(_ baselines: [String: Date]) -> RenamePlan {
        RenamePlan(source: source, destination: destination, edits: edits,
                   unrewritable: unrewritable, baselines: baselines)
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
        var edits: [LinkEdit] = []
        var unrewritable: [UnrewritableLink] = []
        for link in inboundLinks {
            guard let newTarget = rewritten(link.rawTarget, to: destination,
                                            vaultRoot: vaultRoot) else {
                // Not "no change needed" — no rewrite EXISTS. Recorded so the
                // rename reports a link it cannot keep working, instead of
                // returning a zero-edit plan that reads as success.
                unrewritable.append(UnrewritableLink(sourceFile: link.sourceFile,
                                                     rawTarget: link.rawTarget))
                continue
            }
            guard newTarget != link.rawTarget else { continue }
            edits.append(LinkEdit(file: link.sourceFile, oldTarget: link.rawTarget,
                                  newTarget: newTarget))
        }
        return RenamePlan(source: source, destination: destination,
                          edits: edits, unrewritable: unrewritable)
    }

    /// Rewrites a single raw link target to reflect `destination`, or returns
    /// `nil` when no sensible rewrite exists — currently only when the target
    /// names an explicit path or extension (so it must track the move) but
    /// `destination` does not live under `vaultRoot`. In that case there is no
    /// vault-relative path to produce, and inventing one (e.g. an absolute
    /// filesystem path) would hand the confirmation UI a corrupted-looking
    /// target that is worse than simply omitting the edit.
    static func rewritten(_ rawTarget: String, to destination: URL,
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
            guard let relative = vaultRelativePath(of: destination.deletingPathExtension(),
                                                    vaultRoot: vaultRoot) else {
                return nil
            }
            newBody = relative
        } else {
            newBody = newBase
        }
        if hadExtension { newBody += ".md" }
        return newBody + fragment
    }

    /// Strips `vaultRoot`'s path components from the front of `path`'s
    /// components, returning `nil` if `path` is not actually nested under
    /// `vaultRoot`. Compares components, not raw strings, so it is immune to
    /// trailing slashes and to the root's path text recurring elsewhere
    /// inside the destination path (a plain `replacingOccurrences` would
    /// mangle both of those cases).
    private static func vaultRelativePath(of path: URL, vaultRoot: URL) -> String? {
        let rootComponents = vaultRoot.standardizedFileURL.pathComponents
        let pathComponents = path.standardizedFileURL.pathComponents
        guard pathComponents.count > rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return pathComponents.suffix(from: rootComponents.count).joined(separator: "/")
    }
}

/// What actually happened when a plan was applied. Partial success is the
/// EXPECTED case, not an error state: a file that changed on disk is skipped
/// so an edit made seconds ago in another app is not destroyed. `apply` does
/// not throw — the caller decides how to present this.
public struct RenameReport: Sendable {
    /// Files whose inbound links were rewritten.
    public let rewritten: [URL]
    /// Files left ALONE because they changed on disk after the plan was
    /// computed. Their links still point at the old name; nothing was lost.
    public let skipped: [URL]
    /// Files that could not be processed, with a human-readable reason. Also
    /// carries plan-time unrewritable links and a refused move.
    public let failed: [(url: URL, reason: String)]
    /// The new location, or nil if the file was not moved.
    public let movedTo: URL?

    public init(rewritten: [URL], skipped: [URL],
                failed: [(url: URL, reason: String)], movedTo: URL?) {
        self.rewritten = rewritten; self.skipped = skipped
        self.failed = failed; self.movedTo = movedTo
    }

    /// True when every file the plan named was handled and the move (if any)
    /// happened. The UI shows a confirmation only for this.
    public var isCompleteSuccess: Bool { skipped.isEmpty && failed.isEmpty }
}

extension LinkRewriter {
    /// Applies one file's edits, refusing if the file changed since `baseline`.
    /// Returns `false` when skipped, `true` when written.
    ///
    /// A nil `baseline` is treated as "changed": we cannot prove the file is
    /// the one we planned against, and this operation edits files the user did
    /// not open. Failing closed costs a redo; failing open costs their text.
    static func applyEdits(_ edits: [LinkEdit], to file: URL, baseline: Date?) throws -> Bool {
        guard let baseline else { return false }
        guard let disk = try? FileManager.default
                .attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
              disk <= baseline else { return false }
        let text = try String(contentsOf: file, encoding: .utf8)
        var out = text
        for edit in edits {
            out = replacingLinkTargets(in: out, from: edit.oldTarget, to: edit.newTarget)
        }
        // Not a skip and not a failure: nothing matched, so there is nothing to
        // write. Rewriting identical bytes would only bump the mtime and make
        // every OTHER open editor think the file changed underneath it.
        guard out != text else { return true }
        try out.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Replaces `[[old]]`, `[[old|display]]`, `![[old]]` and `[t](old)` while
    /// leaving the display text and the surrounding document untouched.
    ///
    /// Delimiter-anchored on BOTH sides on purpose: an unanchored replacement
    /// of `Design` would also hit `[[Design Notes]]`, the word "design" in a
    /// sentence, and the frontmatter. `![[x]]` needs no separate case — its
    /// `[[x]]` suffix is matched by the wikilink case.
    static func replacingLinkTargets(in text: String, from old: String,
                                     to new: String) -> String {
        var out = text
        for close in ["]]", "|", "#"] {
            out = out.replacingOccurrences(of: "[[\(old)\(close)",
                                           with: "[[\(new)\(close)")
        }
        out = out.replacingOccurrences(of: "](\(old))", with: "](\(new))")
        return out
    }
}
