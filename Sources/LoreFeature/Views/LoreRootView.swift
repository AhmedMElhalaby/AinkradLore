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
                NoteEditorPane(store: store, note: note, theme: theme)
                    .id(note.id)
            } else {
                Text("Select or ⌘N to capture")
                    .foregroundStyle(theme.tokens.foreground.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.tokens.background)
    }

    private func openSelected(_ row: IndexRow) { openNote = try? store.load(row) }
    private func quickCapture() {
        guard let note = try? store.create(title: "") else { return }
        openNote = note
        selected = store.rows.first { $0.id == note.id }
    }
}
