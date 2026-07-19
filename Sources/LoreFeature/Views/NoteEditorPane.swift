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
            message: "This note was edited outside Lore. Load the version from disk? Unsaved changes here will be lost.",
            confirmTitle: "Load from disk",
            isDestructive: true) { loadFromDisk() }
        .ainkradConfirmDialog(
            isPresented: $showDelete,
            title: "Delete note",
            message: "Delete “\(note.title.isEmpty ? "Untitled" : note.title)”? This removes the file from disk.",
            confirmTitle: "Delete",
            isDestructive: true) { deleteNote() }
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
            try? store.save(note)
        }
    }
}
