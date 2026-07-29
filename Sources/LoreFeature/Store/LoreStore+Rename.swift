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
        var unchanged: [URL] = []
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
            // The collision guard above is not the only way `moveItem` can
            // fail. A move into a folder that does not exist, or one we cannot
            // write to, reaches the SAME mass-link-break through the other
            // entry point: every inbound link repointed at a location the file
            // never arrives at. Checked here, before the first write.
            let parent = plan.destination.deletingLastPathComponent()
            var parentIsDirectory: ObjCBool = false
            let parentExists = FileManager.default.fileExists(
                atPath: parent.path, isDirectory: &parentIsDirectory)
            guard parentExists, parentIsDirectory.boolValue else {
                failed.append((parent, "The destination folder does not exist."))
                return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
            }
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                failed.append((parent, "The destination folder is not writable."))
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
        // Session identity, paired with the path it held BEFORE the move. Every
        // later decision (reload, skip) keys off this, never off `session.url`:
        // `adoptRenamed` repoints that URL, so a self-linking document — both
        // the move source AND a rewrite target — would never match its own
        // pre-move path afterwards, keep pre-rewrite text, and revert its own
        // self-link to the old, now-dangling name on the next save.
        var affected: [(session: DocumentSession, path: String)] = []
        // Files a tab still holds unsaved edits to. NOT written at all.
        var blockedByUnsavedEdits: Set<String> = []

        for session in tabs {
            let path = VaultIndexCoordinator.canonical(session.url).path
            let isSource = isMove && path == plan.source.path
            let isEdited = editedByFile[path] != nil
            if isSource { sourceSessions.append(session) }
            guard isEdited || isSource else { continue }
            affected.append((session, path))
            if session.isDirty && !session.isReadOnly {
                if (try? session.saveNow()) != nil, baselines[path] != nil {
                    baselines[path] = Self.mtimeOnDisk(session.url)
                }
            }
            session.cancelPendingSave()
            // The flush can REFUSE: a session that was already `conflict` when
            // the plan was computed re-throws `externalChange` and stays dirty.
            // The plan-time baseline was captured AFTER that external edit, so
            // the mtime guard would happily write the file, and the reload
            // below would then replace the engine's contents — destroying the
            // user's unsaved text with no dialog and no report entry. So a
            // still-dirty session takes its file out of the rewrite set
            // entirely: nothing is written, nothing is reloaded, and the
            // session keeps its `isDirty`/`conflict` for the user to resolve.
            if isEdited && session.isDirty { blockedByUnsavedEdits.insert(path) }
        }

        // Links FIRST, then the move.
        var writtenPaths: Set<String> = []
        for (path, edits) in editedByFile {
            let file = edits[0].file
            guard !blockedByUnsavedEdits.contains(path) else {
                skipped.append(file)
                continue
            }
            do {
                switch try LinkRewriter.applyEdits(edits, to: file, baseline: baselines[path]) {
                case .written:   rewritten.append(file); writtenPaths.insert(path)
                case .unchanged: unchanged.append(file)
                case .skipped:   skipped.append(file)
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
                transferOpenMTime(from: plan.source, to: plan.destination)
            } catch {
                failed.append((plan.source, error.localizedDescription))
            }
        }

        // Reload sessions whose file we actually WROTE, so the editor does not
        // keep showing pre-rewrite text and then save it back.
        // `resolveByReloading` bumps `reloadGeneration`, which the editor's
        // view identity uses. Matched by session identity against the pre-move
        // path (see `affected`). The `isDirty` guard is belt-and-braces: such a
        // session is already excluded from `writtenPaths`, and reloading one
        // would discard unsaved text.
        for entry in affected where writtenPaths.contains(entry.path) {
            guard !entry.session.isDirty else { continue }
            try? entry.session.resolveByReloading()
        }

        // Re-armed: the window is a fixed 1s from the START of `apply`, and a
        // rename touching many files can outlive it — the watcher would then
        // wake mid-apply and queue a whole-vault rescan that our own `rebuild()`
        // is about to make redundant.
        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)
        // The index still holds the old path and the old link targets.
        try? rebuild()

        // The moved file's own entry must be reported at its NEW path: it was
        // rewritten under the old name, which no longer exists by the time the
        // UI renders the report.
        let reportedRewrites = rewritten.map {
            (moved != nil && $0.path == plan.source.path) ? plan.destination : $0
        }
        return RenameReport(rewritten: reportedRewrites.sorted { $0.path < $1.path },
                            skipped: skipped.sorted { $0.path < $1.path },
                            unchanged: unchanged.sorted { $0.path < $1.path },
                            failed: failed, movedTo: moved)
    }
}
