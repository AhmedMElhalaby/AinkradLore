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
    @State private var hovering: DocumentSession.ID?

    /// Tall enough that a `.sm`-padded tab plus its chamfer sits fully INSIDE
    /// the bar. At the old 32 the chamfer was clipped by the bar's own edge.
    private static let barHeight: CGFloat = LoreMetrics.tabBarHeight

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
            .padding(.vertical, AinkradSpacing.xs)
        }
        .frame(height: Self.barHeight)
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
        HStack(spacing: AinkradSpacing.sm) {
            Text(session.title.isEmpty ? session.url.lastPathComponent : session.title)
                .lineLimit(1)
            if session.isReadOnly {
                AinkradIconGlyph(systemName: "lock", size: 10)
            }
            if session.isDirty {
                Circle().frame(width: 6, height: 6)
                    .foregroundStyle(theme.tokens.accentSecondary)
            }
            closeButton(session)
        }
        .padding(.horizontal, AinkradSpacing.sm)
        .padding(.vertical, AinkradSpacing.sm)
        .background(ChamferShape(cut: LoreMetrics.chamfer).fill(store.selectedTab === session
                    ? theme.tokens.accentSecondary.opacity(0.2) : .clear))
        .clipShape(ChamferShape(cut: LoreMetrics.chamfer))
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(session); onSelect(session) }
    }

    /// A secondary affordance, not a peer of the tab's own name. Reaches full
    /// contrast only on hover; its HIT TARGET stays 20×20 either way, because
    /// smaller on screen must not mean harder to hit.
    @ViewBuilder
    private func closeButton(_ session: DocumentSession) -> some View {
        let name = session.title.isEmpty ? session.url.lastPathComponent : session.title
        Button {
            attemptClose(session)
        } label: {
            AinkradIconGlyph(systemName: "xmark", size: 9)
                .foregroundStyle(theme.tokens.foreground.opacity(hovering == session.id ? 0.9 : 0.45))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? session.id : nil }
        .accessibilityLabel("Close \(name)")
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
