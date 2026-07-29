import SwiftUI
import AinkradAppKit

struct TabBarView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    /// Called when a tab is activated, so the root view can drop a stale
    /// open-failure it may still be showing.
    var onSelect: (DocumentSession) -> Void = { _ in }

    /// The session whose close was REFUSED — `closeTab` returned false, meaning
    /// it still holds unsaved work and is still open. We keep the tab and ask.
    @State private var refused: DocumentSession?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AinkradSpacing.xs) {
                // Identity is `session.id`, never `session.url`: a session
                // adopting a copy (`resolveBySavingCopy`) changes its url and
                // would otherwise be torn down and rebuilt mid-edit.
                ForEach(store.tabs) { session in
                    tab(session)
                }
            }
            .padding(.horizontal, AinkradSpacing.sm)
        }
        .frame(height: 32)
        .overlay(closeShortcut)
        .ainkradConfirmDialog(
            isPresented: refusalBinding,
            title: "Unsaved changes",
            message: refusalMessage,
            confirmTitle: "Close anyway",
            isDestructive: true) {
                if let session = refused { store.closeTab(session, force: true) }
                refused = nil
            }
    }

    @ViewBuilder
    private func tab(_ session: DocumentSession) -> some View {
        HStack(spacing: AinkradSpacing.xs) {
            Text(session.title.isEmpty ? session.url.lastPathComponent : session.title)
                .lineLimit(1)
            if session.isReadOnly {
                AinkradIconGlyph(systemName: "lock", size: 10)
            }
            if session.isDirty {
                Circle().frame(width: 6, height: 6)
                    .foregroundStyle(theme.tokens.accentSecondary)
            }
            AinkradIconButton(systemName: "xmark") { attemptClose(session) }
        }
        .padding(.horizontal, AinkradSpacing.sm)
        .padding(.vertical, AinkradSpacing.xs)
        .background(store.selectedTab === session
                    ? theme.tokens.accentSecondary.opacity(0.2) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(session); onSelect(session) }
    }

    /// ⌘W closes the selected tab, through the same refusal path as the button.
    private var closeShortcut: some View {
        Button("Close tab") {
            if let session = store.selectedTab { attemptClose(session) }
        }
        .keyboardShortcut("w", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// `closeTab` is refusable: false means the tab is STILL OPEN with unsaved
    /// work whose save failed or conflicted. Ignoring that return is exactly
    /// the data-loss bug this path exists to prevent, so we surface why and
    /// make discarding an explicit choice.
    private func attemptClose(_ session: DocumentSession) {
        if !store.closeTab(session) { refused = session }
    }

    private var refusalBinding: Binding<Bool> {
        Binding(get: { refused != nil }, set: { if !$0 { refused = nil } })
    }

    private var refusalMessage: String {
        guard let session = refused else { return "" }
        let name = session.title.isEmpty ? session.url.lastPathComponent : session.title
        if session.conflict {
            return "“\(name)” changed on disk outside Lore, so its unsaved edits couldn't be "
                 + "saved. Close anyway and those edits are lost — or cancel and resolve the "
                 + "conflict in the document."
        }
        if let error = session.lastSaveError {
            return "“\(name)” couldn't be saved: \(error.localizedDescription). "
                 + "Close anyway and its unsaved edits are lost."
        }
        return "“\(name)” still has unsaved changes that couldn't be saved. "
             + "Close anyway and they are lost."
    }
}
