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

    /// Non-nil when the operation was refused at PLAN time, before anything was
    /// computed — today only an invalid new name (empty, a path separator, `.`,
    /// `..`, or a destination outside the vault root). A refusal is carried on
    /// the plan rather than thrown so the preview UI can render it beside every
    /// other outcome, and so `apply` has exactly one place to report it.
    ///
    /// `apply` writes NOTHING and creates NOTHING for a refused plan.
    public let refusal: String?

    public init(source: URL, destination: URL, edits: [LinkEdit],
                unrewritable: [UnrewritableLink] = [],
                baselines: [String: Date] = [:],
                refusal: String? = nil) {
        self.source = source; self.destination = destination; self.edits = edits
        self.unrewritable = unrewritable; self.baselines = baselines
        self.refusal = refusal
    }

    /// A copy carrying freshly-read mtimes. Keeps the mtime read (I/O) out of
    /// `LinkRewriter` while keeping the value on the plan, where `apply` needs
    /// it and where the preview UI (Task 10) can see it too.
    public func withBaselines(_ baselines: [String: Date]) -> RenamePlan {
        RenamePlan(source: source, destination: destination, edits: edits,
                   unrewritable: unrewritable, baselines: baselines,
                   refusal: refusal)
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
    ///
    /// Deliberately does NOT use `.standardizedFileURL` here, despite the
    /// name suggesting it is the right tool: `stringByStandardizingPath`
    /// (what it calls under the hood) strips a leading `/private` from
    /// `/private/var`, `/private/tmp`, `/private/etc` — but ONLY when the
    /// shortened path can be verified to resolve to the same file, which
    /// requires that shortened path to actually exist. `vaultRoot` almost
    /// always exists (it is a real, already-active vault) and gets stripped;
    /// `path` is a rename/move DESTINATION that, for a folder rename or a
    /// move into a not-yet-created folder, does not exist yet and is left
    /// alone. The two sides then disagree only in whether they still carry
    /// `/private`, every prefix match fails, and every explicit-path or
    /// explicit-extension inbound link for that document is silently dropped
    /// as "outside the vault" — with no error, just an empty edit list. Both
    /// `vaultRoot` and `path` arrive here already canonicalized consistently
    /// by the caller (`LoreStore+Rename.swift` sources everything through
    /// `VaultIndexCoordinator.canonical`), so comparing raw path components
    /// is enough and does not need — must NOT use — a second pass through
    /// path standardization.
    private static func vaultRelativePath(of path: URL, vaultRoot: URL) -> String? {
        let rootComponents = vaultRoot.pathComponents
        let pathComponents = path.pathComponents
        guard pathComponents.count > rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return pathComponents.suffix(from: rootComponents.count).joined(separator: "/")
    }
}

/// Why one file was left alone by a rewrite pass.
///
/// Carried per file rather than implied by the list it lands in, because
/// `skipped` has THREE causes that are not interchangeable to the person
/// reading the report: "another app edited this file" is a fact about the
/// vault, while "your own tab has unsaved edits" is an instruction to go and
/// save. The first cut of the confirmation UI described every skip as "changed
/// by another app and left alone", which is simply false for the unsaved-edits
/// case — a report that misattributes a cause is worse than one that omits it,
/// because the user acts on it.
public enum SkipReason: Sendable, Equatable {
    /// The file's mtime moved past the plan-time baseline: someone edited it
    /// between the preview and the confirmation.
    case changedOnDisk
    /// No usable baseline, or the mtime could not be read. We cannot prove the
    /// file is the one we planned against, so we do not write it.
    case unverifiable
    /// An open tab still holds unsaved edits to it and flushing them refused,
    /// so the file was excluded from the rewrite entirely.
    case unsavedEdits

    /// Completes the sentence "This file …". Present tense, because each of
    /// these is still true when the user reads it.
    public var phrase: String {
        switch self {
        case .changedOnDisk: "was changed outside Lore after the preview"
        case .unverifiable: "could not be confirmed unchanged since the preview"
        case .unsavedEdits: "has unsaved edits in an open tab"
        }
    }
}

/// One file a rewrite pass declined to write, with the reason it declined.
public struct SkippedFile: Sendable, Equatable {
    public let url: URL
    public let reason: SkipReason
    public init(url: URL, reason: SkipReason) {
        self.url = url; self.reason = reason
    }
}

/// What actually happened when a plan was applied. Partial success is the
/// EXPECTED case, not an error state: a file that changed on disk is skipped
/// so an edit made seconds ago in another app is not destroyed. `apply` does
/// not throw — the caller decides how to present this.
public struct RenameReport: Sendable {
    /// Files whose inbound links were rewritten.
    public let rewritten: [URL]
    /// Files left ALONE, each carrying WHY — see `SkipReason`. Their links still
    /// point at the old name; nothing was lost.
    public let skipped: [SkippedFile]
    /// Files that were opened and matched nothing — no delimiter-anchored
    /// occurrence of the old target survived to rewrite time. Nothing was
    /// written, so they must not be listed as `rewritten` (an untruthful
    /// report) nor as `skipped` (nothing was refused).
    public let unchanged: [URL]
    /// Files that could not be processed, with a human-readable reason. Also
    /// carries plan-time unrewritable links and a refused move.
    public let failed: [(url: URL, reason: String)]
    /// The new location, or nil if the file was not moved.
    public let movedTo: URL?

    public init(rewritten: [URL], skipped: [SkippedFile], unchanged: [URL] = [],
                failed: [(url: URL, reason: String)], movedTo: URL?) {
        self.rewritten = rewritten; self.skipped = skipped
        self.unchanged = unchanged
        self.failed = failed; self.movedTo = movedTo
    }

    /// True when every file the plan named was handled and the move (if any)
    /// happened. The UI shows a confirmation only for this.
    public var isCompleteSuccess: Bool { skipped.isEmpty && failed.isEmpty }
}

extension LinkRewriter {
    /// What `applyEdits` did to one file. Three states, not a `Bool`: "opened
    /// it and nothing matched" is neither a write nor a refusal, and collapsing
    /// it into either one makes the report lie — and, worse, drags that file's
    /// tab through a `resolveByReloading()` it never needed.
    /// Explicitly `Equatable`: an enum stops synthesizing it as soon as a case
    /// carries an associated value, and `.skipped` now carries its cause.
    enum EditOutcome: Equatable {
        case written
        /// No delimiter-anchored occurrence matched. Nothing was written.
        case unchanged
        /// Refused, with the cause: the file changed on disk since the plan, or
        /// we have no baseline to compare against. The cause travels with the
        /// outcome so the report can word each case correctly instead of
        /// describing every skip as somebody else's edit.
        case skipped(SkipReason)
    }

    /// Applies one file's edits, refusing if the file changed since `baseline`.
    ///
    /// A nil `baseline` is treated as "changed": we cannot prove the file is
    /// the one we planned against, and this operation edits files the user did
    /// not open. Failing closed costs a redo; failing open costs their text.
    static func applyEdits(_ edits: [LinkEdit], to file: URL,
                           baseline: Date?) throws -> EditOutcome {
        guard let baseline else { return .skipped(.unverifiable) }
        // Split from the comparison so the two causes stay distinguishable in
        // the report: an unreadable mtime is "cannot verify", a newer one is
        // "somebody edited it". Same behaviour, honest wording.
        guard let disk = try? FileManager.default
                .attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        else { return .skipped(.unverifiable) }
        guard disk <= baseline else { return .skipped(.changedOnDisk) }
        let text = try String(contentsOf: file, encoding: .utf8)
        var out = text
        for edit in edits {
            out = replacingLinkTargets(in: out, from: edit.oldTarget, to: edit.newTarget)
        }
        // Rewriting identical bytes would only bump the mtime and make every
        // OTHER open editor think the file changed underneath it.
        guard out != text else { return .unchanged }
        try out.write(to: file, atomically: true, encoding: .utf8)
        return .written
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
