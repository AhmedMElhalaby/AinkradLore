import Foundation

// Trash-backed deletion. Lives in its own file so `LoreStore.swift` and
// `LoreStore+Rename.swift` both stay well under the 500-line ceiling.
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
    /// A DIRTY tab on the document is flushed to disk first, not discarded and
    /// not left to block the delete forever: the user asked to delete this
    /// document, dirty or not, and the unsaved text is exactly as recoverable
    /// as the rest of the file once both are sitting in the Trash together.
    /// Silently dropping the edit would lose work with no trace; refusing to
    /// delete until the user resolves the tab would make "delete" sometimes
    /// not delete. Flushing first means nothing is lost that a Trash restore
    /// cannot recover. `cancelPendingSave()` still runs unconditionally
    /// afterwards — a debounced autosave firing after the file is trashed
    /// would recreate the very file the user just deleted, the exact defect
    /// Task 7 found and fixed for rename.
    @discardableResult
    public func trash(_ row: IndexRow) throws -> Int {
        let path = VaultIndexCoordinator.canonical(row.path)
        let inbound = inboundLinkCount(to: path)

        for session in tabs where VaultIndexCoordinator.canonical(session.url) == path {
            if session.isDirty && !session.isReadOnly {
                try? session.saveNow()
            }
            session.cancelPendingSave()
            _ = closeTab(session, force: true)
        }

        do {
            try FileManager.default.trashItem(at: row.path, resultingItemURL: nil)
        } catch {
            throw LoreError.trashFailed(row.path, error.localizedDescription)
        }
        try? coordinator.removeFromIndex(path)
        return inbound
    }
}
