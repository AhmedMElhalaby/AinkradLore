import SwiftUI
import AinkradAppKit

struct LoreRootView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @State private var query = ""
    @State private var selected: IndexRow?
    /// The file the user most recently asked to open. `LoreStore.openError` is
    /// only cleared by the next SUCCESSFUL open, so it can outlive the click
    /// that produced it; gating the fallback viewer on this makes sure a stale
    /// error never shadows a document that opened perfectly well.
    @State private var attempted: URL?

    var body: some View {
        HStack(spacing: 0) {
            NoteListView(store: store, query: $query, selected: $selected, theme: theme,
                         onSelect: openRow, onNew: quickCapture, onDelete: deleteRow)
                .frame(width: 280)
            VStack(spacing: 0) {
                if !store.tabs.isEmpty {
                    TabBarView(store: store, theme: theme,
                               onSelect: { _ in attempted = nil })
                }
                content
            }
        }
        .background(theme.tokens.background)
        .environment(\.ainkradTheme, theme.tokens)
    }

    @ViewBuilder private var content: some View {
        if let failure = store.openError, failure.url == attempted {
            FallbackViewer(url: failure.url, error: failure.error, theme: theme)
        } else if let session = store.selectedTab {
            // Identity is the session's stable id — NOT its url, which changes
            // when the session adopts a "save a copy" resolution.
            DocumentPane(store: store, session: session, theme: theme)
                .id(session.id)
        } else {
            AinkradEmptyState(
                icon: "book.closed",
                title: "No document open",
                message: "Select a document from the list, or press ⌘N to capture a new one.",
                actionTitle: "New note",
                action: quickCapture)
        }
    }

    private func openRow(_ row: IndexRow) {
        selected = row
        attempted = row.path
        store.open(row)
    }

    private func deleteRow(_ row: IndexRow) {
        deleteDocument(row, in: store)
        if selected?.path == row.path { selected = nil }
        if attempted == row.path { attempted = nil }
    }

    private func quickCapture() {
        guard let note = try? store.create(title: "") else { return }
        attempted = note.path
        store.open(url: note.path)
        selected = store.rows.first { $0.path == note.path }
    }
}

/// Testable core of the list's delete affordance (which moved off the old
/// `NoteEditorPane` when that view was deleted).
///
/// The tab is closed BEFORE the file is removed, and forced: a dirty session's
/// pending save would otherwise either refuse the close or write the file back
/// out again after the delete.
@MainActor
func deleteDocument(_ row: IndexRow, in store: LoreStore) {
    if let tab = store.tabs.first(where: { $0.url == row.path }) {
        store.closeTab(tab, force: true)
    }
    try? store.delete(row)
}
