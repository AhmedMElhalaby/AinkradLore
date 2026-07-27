import SwiftUI
import AinkradAppKit

struct NoteEditorPane: View {
    @Bindable var store: LoreStore
    @State var note: Note
    let theme: HostTheme
    let onDelete: () -> Void
    @State private var showReload = false
    @State private var showDelete = false
    @State private var saveTask: Task<Void, Never>?
    /// Set when `loadFromDisk` runs, so dismissing the conflict prompt can tell
    /// "the user took the disk version" from "the user dismissed it, meaning
    /// keep mine". Without this a declined prompt would leave the editor
    /// unable to save at all — every autosave would keep hitting the same
    /// conflict and the user's typing would never reach disk.
    @State private var resolvedByReloading = false

    init(store: LoreStore, note: Note, theme: HostTheme, onDelete: @escaping () -> Void) {
        self.store = store
        self._note = State(initialValue: note)
        self.theme = theme
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AinkradSpacing.sm) {
                AinkradTextField(text: $note.title, placeholder: "Title")
                    .onChange(of: note.title) { scheduleSave() }
                AinkradIconButton(systemName: "trash") { showDelete = true }
            }
            .padding(AinkradSpacing.md)

            MarkdownEditor(text: $note.body, tokens: theme.tokens)
                .onChange(of: note.body) { scheduleSave() }
        }
        .background(theme.tokens.background)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if store.externalChangeDetected(for: note) { showReload = true }
        }
        .ainkradConfirmDialog(
            isPresented: $showReload,
            title: "Note changed on disk",
            message: "This note was edited outside Lore. Load the version from disk and discard your edits here, "
                + "or dismiss to keep your version and overwrite the file.",
            confirmTitle: "Load from disk",
            isDestructive: true) { resolvedByReloading = true; loadFromDisk() }
        .onChange(of: showReload) { wasShowing, isShowing in
            // Dismissed without loading == "keep mine". Resolve the conflict by
            // saving over the file, so the editor isn't left permanently unable
            // to persist anything.
            guard wasShowing, !isShowing else { return }
            if resolvedByReloading { resolvedByReloading = false } else { forceSave() }
        }
        .ainkradConfirmDialog(
            isPresented: $showDelete,
            title: "Delete note",
            message: "Delete “\(note.title.isEmpty ? "Untitled" : note.title)”? This removes the file from disk.",
            confirmTitle: "Delete",
            isDestructive: true) { deleteNote() }
    }

    /// Deliberate overwrite after the user chose to keep their version.
    private func forceSave() {
        saveTask?.cancel()
        try? store.save(note, overwritingExternalChanges: true)
    }

    private func loadFromDisk() {
        let row = IndexRow(path: note.path, id: note.id, title: note.title,
                           tags: note.tags, updated: note.updated)
        if let fresh = try? store.load(row) { note = fresh }
    }

    private func deleteNote() {
        let row = IndexRow(path: note.path, id: note.id, title: note.title,
                           tags: note.tags, updated: note.updated)
        try? store.delete(row)
        onDelete()
    }

    private func scheduleSave(immediate: Bool = false) {
        saveTask?.cancel()
        saveTask = Task {
            if !immediate { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard !Task.isCancelled else { return }
            do {
                try store.save(note)
            } catch LoreError.externalChange {
                // The file changed underneath us. Previously `try?` swallowed
                // this and the autosave clobbered the external edit; now the
                // user gets the same reload prompt they'd get on app
                // re-activation, and their in-editor text is left intact until
                // they choose.
                showReload = true
            } catch {
                // Nothing else is recoverable here; keep the editor's text and
                // let the next keystroke retry rather than dropping the note.
            }
        }
    }
}
