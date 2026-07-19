import SwiftUI
import AinkradAppKit

struct LoreRootView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @State private var query = ""
    @State private var selected: IndexRow?
    @State private var openNote: Note?

    var body: some View {
        HStack(spacing: 0) {
            NoteListView(store: store, query: $query, selected: $selected, theme: theme,
                         onSelect: openSelected, onNew: quickCapture)
                .frame(width: 280)
            if let note = openNote {
                NoteEditorPane(store: store, note: note, theme: theme, onDelete: closeNote)
                    .id(note.id)
            } else {
                AinkradEmptyState(
                    icon: "book.closed",
                    title: "No note open",
                    message: "Select a note from the list, or press ⌘N to capture a new one.",
                    actionTitle: "New note",
                    action: quickCapture)
            }
        }
        .background(theme.tokens.background)
        .environment(\.ainkradTheme, theme.tokens)
    }

    private func openSelected(_ row: IndexRow) { openNote = try? store.load(row) }

    private func closeNote() { openNote = nil; selected = nil }

    private func quickCapture() {
        guard let note = try? store.create(title: "") else { return }
        openNote = note
        selected = store.rows.first { $0.id == note.id }
    }
}
