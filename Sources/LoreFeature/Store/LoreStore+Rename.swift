import Foundation

// Renaming and moving a document: the first operation in Lore that writes to
// files the user never opened. Three properties are load-bearing, in order:
//
//  1. ORDERING. Inbound links are rewritten BEFORE the file moves. Reversed,
//     a crash mid-operation leaves a renamed file with every inbound link
//     dangling. In this order, a crash leaves links pointing at a
//     not-yet-renamed file — still resolvable, and re-running the rename
//     fixes it. This is not a preference.
//  2. NEVER OVERWRITE AN EXTERNAL EDIT. Every file is checked against the
//     mtime captured at PLAN time; one that moved is skipped and reported.
//     With Obsidian open on the same vault this is not hypothetical.
//  3. OPEN TABS. A session holding pre-rewrite content would clobber the
//     rewrite on its next autosave, so pending saves are disarmed first and
//     the sessions reloaded after.
//
// It lives in its own file because `LoreStore.swift` is at 336 lines and the
// project ceiling is 500.
extension LoreStore {

    // MARK: - Planning

    /// Computes the change set for renaming `source` to `newName` (a basename,
    /// no extension). Nothing is written.
    public func plan(rename source: URL, to newName: String) -> RenamePlan {
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent(newName)
            .appendingPathExtension(source.pathExtension)
        return planMove(source, to: destination)
    }

    /// Moving is renaming without the name change: it must still rewrite,
    /// because a move changes how an explicit-path link resolves.
    public func plan(move source: URL, toFolder folder: URL) -> RenamePlan {
        planMove(source, to: folder.appendingPathComponent(source.lastPathComponent))
    }

    /// The single place source, destination and vault root are canonicalized.
    ///
    /// `LinkRewriter` computes a vault-relative target by comparing path
    /// COMPONENTS against `vaultRoot`. If the two sides come from different
    /// resolutions — `FileManager`'s enumerator yields `/private/tmp/...`
    /// while a caller-built URL stays `/tmp/...` — the prefix match fails,
    /// `rewritten` returns nil, and every edit is silently dropped: a plan
    /// with zero edits, a rename that looks clean, and every inbound link
    /// quietly broken. Task 6's review found exactly this. Sourcing all three
    /// through `VaultIndexCoordinator.canonical` is what prevents it.
    private func planMove(_ source: URL, to destination: URL) -> RenamePlan {
        let canonicalSource = VaultIndexCoordinator.canonical(source)
        let canonicalDestination = Self.canonicalizingDestination(destination)
        let root = VaultIndexCoordinator.canonical(
            vaultRoot ?? canonicalSource.deletingLastPathComponent())

        let inbound = coordinator.inboundLinks(to: canonicalSource)
        let plan = LinkRewriter.plan(renaming: canonicalSource,
                                     to: canonicalDestination,
                                     inboundLinks: inbound,
                                     vaultRoot: root)
        // Baselines are read HERE, not in `apply`. Reading them inside `apply`
        // (microseconds before comparing them) makes the external-change guard
        // tautological: it can never fire, and requirement 2 silently
        // evaporates while the code still looks like it enforces it.
        var baselines: [String: Date] = [:]
        for file in plan.affectedFiles {
            baselines[file.path] = Self.mtimeOnDisk(file)
        }
        return plan.withBaselines(baselines)
    }

    /// `realpath(3)` fails on a path that does not exist yet — and a rename
    /// destination never exists yet. Canonicalizing the (existing) parent
    /// directory and re-appending the filename gives the destination the same
    /// resolution as everything else.
    private static func canonicalizingDestination(_ destination: URL) -> URL {
        VaultIndexCoordinator.canonical(destination.deletingLastPathComponent())
            .appendingPathComponent(destination.lastPathComponent)
    }

    private static func mtimeOnDisk(_ url: URL) -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    // MARK: - Applying

    /// Applies `plan`. Never throws: partial success is the expected outcome,
    /// and the caller (the confirmation UI, Task 10) decides how to present it.
    @discardableResult
    public func apply(_ plan: RenamePlan) -> RenameReport {
        var rewritten: [URL] = []
        var skipped: [URL] = []
        var failed: [(url: URL, reason: String)] = []

        // Links the planner could not rewrite are surfaced up front. A rename
        // that leaves a link broken must not report success.
        for link in plan.unrewritable {
            failed.append((link.sourceFile,
                           "Could not rewrite the link “\(link.rawTarget)” — "
                           + "the new location is outside the vault."))
        }

        let isMove = plan.source.path != plan.destination.path

        // Refusals are checked BEFORE anything is written. The obvious
        // implementation rewrites first and discovers the collision after, at
        // which point every inbound link has been repointed at a name that
        // will never exist — a self-inflicted mass link break.
        if isMove {
            guard FileManager.default.fileExists(atPath: plan.source.path) else {
                failed.append((plan.source, "The file no longer exists."))
                return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
            }
            if FileManager.default.fileExists(atPath: plan.destination.path) {
                failed.append((plan.destination, "A file with that name already exists."))
                return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
            }
        }

        // Our own writes would otherwise wake `FolderWatcher` once per file and
        // each callback is a whole-vault rescan. One `rebuild()` at the end is
        // the correct amount.
        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)

        var baselines = plan.baselines
        let editedByFile = Dictionary(grouping: plan.edits, by: { $0.file.path })

        // Disarm every debounced autosave that could land on top of a rewrite,
        // INCLUDING the renamed document's own. A session holding unsaved text
        // is flushed first so its edits are on disk before we touch the file —
        // cancelling alone would leave them to be overwritten by the rewrite
        // and then erased by the reload. Because that flush is OUR write, the
        // baseline is refreshed with it: it is not an external change.
        // Resolved BEFORE the move, never after: `canonical` is `realpath(3)`,
        // which FAILS on a path that no longer exists and then hands back the
        // unresolved URL. Matching the source tab after `moveItem` therefore
        // compared `/var/...` against `/private/var/...` and silently found
        // nothing — the renamed document's own tab kept pointing at a file
        // that was gone.
        var sourceSessions: [DocumentSession] = []

        for session in tabs {
            let path = VaultIndexCoordinator.canonical(session.url).path
            let isSource = isMove && path == plan.source.path
            if isSource { sourceSessions.append(session) }
            guard editedByFile[path] != nil || isSource else { continue }
            if session.isDirty && !session.isReadOnly {
                // A refusal here (conflict) is correct to ignore: the baseline
                // then stays at its plan-time value and the file is skipped
                // below rather than overwritten.
                if (try? session.saveNow()) != nil, baselines[path] != nil {
                    baselines[path] = Self.mtimeOnDisk(session.url)
                }
            }
            session.cancelPendingSave()
        }

        // Links FIRST, then the move.
        for (path, edits) in editedByFile {
            let file = edits[0].file
            do {
                if try LinkRewriter.applyEdits(edits, to: file, baseline: baselines[path]) {
                    rewritten.append(file)
                } else {
                    skipped.append(file)
                }
            } catch {
                failed.append((file, error.localizedDescription))
            }
        }

        var moved: URL?
        if isMove {
            do {
                try FileManager.default.moveItem(at: plan.source, to: plan.destination)
                moved = plan.destination
                for session in sourceSessions { session.adoptRenamed(plan.destination) }
            } catch {
                failed.append((plan.source, error.localizedDescription))
            }
        }

        // Reload sessions whose file we rewrote, so the editor does not keep
        // showing pre-rewrite text and then save it back. `resolveByReloading`
        // bumps `reloadGeneration`, which the editor's view identity uses.
        let rewrittenPaths = Set(rewritten.map(\.path))
        for session in tabs
        where rewrittenPaths.contains(VaultIndexCoordinator.canonical(session.url).path) {
            try? session.resolveByReloading()
        }

        // The index still holds the old path and the old link targets.
        try? rebuild()

        return RenameReport(rewritten: rewritten.sorted { $0.path < $1.path },
                            skipped: skipped.sorted { $0.path < $1.path },
                            failed: failed, movedTo: moved)
    }
}
