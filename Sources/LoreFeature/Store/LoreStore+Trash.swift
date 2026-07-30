import Foundation

// Trash-backed deletion — the ONLY deletion path in Lore. The legacy
// `LoreStore.delete(_:)`, a permanent `removeItem` whose two callers each
// reached it with a live "a debounced autosave recreates the deleted file"
// defect, is gone: a permanent-delete path with a known resurrection bug has
// no business outliving the milestone that added a safe one.
//
// Lives in its own file so `LoreStore.swift` and the two rename files all stay
// under the 500-line ceiling.
extension LoreStore {

    /// Moves `row`'s file to the macOS Trash.
    ///
    /// Returns how many documents currently link to it, so the caller (Task
    /// 10's UI) can warn before the user confirms. Those inbound links are
    /// deliberately NOT rewritten: an unresolved link to a deleted note is the
    /// correct outcome, and is how the user later finds what broke.
    ///
    /// NEVER falls back to `removeItem` on failure — a network volume or an
    /// external drive with no `.Trashes` throws `trashFailed` instead. Quietly
    /// doing something less safe (a permanent delete) than the user asked for
    /// (a recoverable one) is its own bug, so this stops before touching the
    /// file.
    ///
    /// ## A tab with UNSAVED edits refuses the delete
    ///
    /// A dirty tab is flushed first, so the unsaved text lands in the Trash
    /// with the rest of the file and a Trash restore recovers exactly what the
    /// user last saw. But that flush can REFUSE — the session was already in
    /// `conflict` (someone else edited the file), or `guardWritable` rejects a
    /// read-only document. The first cut ignored that (`try? saveNow()`) and
    /// then force-closed the tab unconditionally, which meant: the file was
    /// trashed carrying STALE content, and the only holder of the user's edits
    /// was destroyed in the same breath. Silently, and with no channel to say
    /// so — `trash` returns an `Int`.
    ///
    /// So a still-dirty session REFUSES the delete, throwing `unsavedEdits`.
    /// The session is left open, dirty, and with its `conflict` intact so the
    /// user can resolve it (reload, overwrite, or save a copy) and delete
    /// again. Deleting is not urgent enough to justify destroying text the user
    /// has never seen saved — and unlike the flush-and-delete outcome, this one
    /// is recoverable by doing nothing.
    ///
    /// Every check runs BEFORE any tab is closed and before the file is
    /// touched, so a refusal leaves the store exactly as it found it.
    @discardableResult
    public func trash(_ row: IndexRow) throws -> Int {
        guard coordinator.hasIndex else { throw LoreError.noVault }
        // `DocumentSession` never canonicalizes the URL it was opened with, so
        // a tab opened via `open(url:)` with a caller-supplied path must be
        // matched canonically or `trash` deletes the file out from under it.
        let path = VaultIndexCoordinator.canonical(row.path)
        let inbound = inboundLinkCount(to: path)
        let sessions = tabs.filter { VaultIndexCoordinator.canonical($0.url) == path }

        // Refuse first, mutate second.
        for session in sessions where session.isDirty {
            if !session.isReadOnly { try? session.saveNow() }
            guard !session.isDirty else {
                throw LoreError.unsavedEdits(
                    path,
                    session.conflict
                        ? "it has unsaved edits that cannot be saved because the file was "
                        + "also changed outside Lore. Resolve the conflict in the open tab "
                        + "(reload, overwrite, or save a copy), then delete it again."
                        : "it has unsaved edits that could not be saved. Resolve the open "
                        + "tab, then delete it again.")
            }
        }

        for session in sessions {
            // Unconditional: a debounced autosave firing after the file is
            // trashed would recreate the very file the user just deleted — the
            // exact defect Task 7 found and fixed for rename.
            session.cancelPendingSave()
            _ = closeTab(session, force: true)
        }

        // Our own mutation. Without this the watcher wakes and queues a
        // whole-vault rescan on top of the targeted `removeFromIndex` below.
        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)
        do {
            try FileManager.default.trashItem(at: row.path, resultingItemURL: nil)
        } catch {
            throw LoreError.trashFailed(row.path, error.localizedDescription)
        }
        // Both spellings: rows written by `indexDocument` carry the caller's
        // path, rows written by a full rescan carry the canonical one, and
        // `remove(path:)` matches exactly.
        try? coordinator.removeFromIndex(row.path)
        if row.path != path { try? coordinator.removeFromIndex(path) }
        forgetOpenMTime(row.path)
        forgetOpenMTime(path)
        return inbound
    }
}
