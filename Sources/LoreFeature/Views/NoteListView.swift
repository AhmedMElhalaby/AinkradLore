import SwiftUI
import AinkradAppKit

struct NoteListView: View {
    @Bindable var store: LoreStore
    @Binding var query: String
    @Binding var selected: IndexRow?
    let theme: HostTheme
    let onSelect: (IndexRow) -> Void
    let onNew: () -> Void

    private var visible: [IndexRow] { query.isEmpty ? store.rows : store.search(query) }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                Button(action: onNew) { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(8)
            .background(theme.tokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visible, id: \.path) { row in
                        Button { selected = row; onSelect(row) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title.isEmpty ? "Untitled" : row.title)
                                    .foregroundStyle(theme.tokens.foreground)
                                if !row.tags.isEmpty {
                                    Text(row.tags.map { "#\($0)" }.joined(separator: " "))
                                        .font(.caption).foregroundStyle(theme.tokens.accentSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(selected?.path == row.path ? theme.tokens.surfaceElevated : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(8)
        .foregroundStyle(theme.tokens.foreground)
    }
}
