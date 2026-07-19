import SwiftUI
import AinkradAppKit

struct NoteEditorPane: View {
    @Bindable var store: LoreStore
    @State var note: Note
    let theme: HostTheme
    @State private var showReload = false
    @State private var saveTask: Task<Void, Never>?

    init(store: LoreStore, note: Note, theme: HostTheme) {
        self.store = store; self._note = State(initialValue: note); self.theme = theme
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $note.title)
                .textFieldStyle(.plain)
                .font(.title2)
                .padding(16)
                .foregroundStyle(theme.tokens.foreground)
                .onChange(of: note.title) { scheduleSave() }
            MarkdownEditor(text: $note.body, tokens: theme.tokens)
                .onChange(of: note.body) { scheduleSave() }
        }
        .background(theme.tokens.background)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if store.externalChangeDetected(for: note) { showReload = true }
        }
        .alert("This note changed on disk", isPresented: $showReload) {
            Button("Keep mine") { scheduleSave(immediate: true) }
            Button("Load disk", role: .destructive) {
                if let fresh = try? store.load(IndexRow(path: note.path, id: note.id,
                    title: note.title, tags: note.tags, updated: note.updated)) { note = fresh }
            }
        }
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
