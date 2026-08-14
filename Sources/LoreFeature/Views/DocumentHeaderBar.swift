import SwiftUI
import AppKit
import AinkradAppKit

/// The open document's identity, save state, and its own actions.
///
/// ## Why the document needed a head
///
/// Until this existed, the ONLY place the open document was named was its tab,
/// and the only thing said about it was a 6pt dirty dot. Nothing on screen
/// answered "which folder is this in?" — a real question in a vault where
/// `Notes.md` can exist in six places — and the document's own actions
/// (rename, move, reveal, delete) were reachable only by finding the file
/// again in the sidebar and right-clicking it, which in tree mode could mean
/// expanding several folders to reach a file that was already open.
///
/// The menu is built from `loreRowMenuItems`, the SAME builder the sidebar's
/// context menu uses. That is deliberate and load-bearing: a destructive
/// affordance defined twice is a destructive affordance reviewed once, and the
/// sidebar's version already routes every path through `SidebarOperations`'
/// confirmations and refusals.
struct DocumentHeaderBar: View {
    let session: DocumentSession
    /// The vault root, for the breadcrumb. Nil renders the filename alone —
    /// with no vault there is no relative path to show.
    let vaultRoot: URL?
    let theme: HostTheme
    /// The row this document corresponds to, when the index knows it. Nil for
    /// a document open from outside the vault, which has no index row and
    /// therefore no rename/move/trash — the menu is simply absent rather than
    /// present and dead.
    let row: IndexRow?
    let ops: SidebarOperations

    @Environment(\.ainkradTypography) private var typo
    /// Ticks only while a "Saved" label is young enough for its wording to
    /// still change. See `saveState` and `RelativeClock`.
    @State private var now = Date()

    private var saveState: DocumentSaveState {
        DocumentSaveState.of(readOnly: session.isReadOnly,
                             hasSaveError: session.lastSaveError != nil,
                             isDirty: session.isDirty,
                             lastSavedAt: session.lastSavedAt)
    }

    var body: some View {
        HStack(spacing: AinkradSpacing.sm) {
            breadcrumb
            Spacer(minLength: AinkradSpacing.sm)
            saveLabel
            if let row {
                AinkradIconButton(systemName: "ellipsis", tooltip: "Document actions") {}
                    .ainkradContextMenu(loreRowMenuItems(row: row, ops: ops))
                    .accessibilityLabel("Document actions")
            }
        }
        .padding(.horizontal, LoreMetrics.gutter)
        .padding(.vertical, AinkradSpacing.xs)
        .background(theme.tokens.surface)
        .task(id: session.id) { await RelativeClock.tick { now = $0 } }
    }

    /// `Vault ▸ Folder ▸ Name`, truncating from the HEAD.
    ///
    /// Head truncation, not tail: when a path is too long the segment the user
    /// needs is the one nearest the file, so the vault name is what should
    /// disappear first. Tail truncation would keep the least useful half.
    private var breadcrumb: some View {
        Text(Self.breadcrumb(for: session.url, root: vaultRoot))
            .font(AinkradFontResolver.font(.body, typography: typo))
            .foregroundStyle(theme.tokens.foreground.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.head)
            .accessibilityLabel("Document \(session.url.lastPathComponent)")
    }

    @ViewBuilder private var saveLabel: some View {
        let label = saveState.label(now: now)
        if !label.isEmpty {
            HStack(spacing: AinkradSpacing.xs) {
                if session.isReadOnly {
                    AinkradIconGlyph(systemName: "lock", size: 10)
                }
                Text(label)
                    .font(AinkradFontResolver.font(.caption, typography: typo))
            }
            // Only a FAILED save earns the danger colour. An ordinary "Saved"
            // in an attention-grabbing tint would train the user to ignore the
            // one reading that matters.
            .foregroundStyle(saveState.isAlarming
                             ? theme.tokens.accentPrimary
                             : theme.tokens.foreground.opacity(0.6))
            .accessibilityLabel(label)
        }
    }

    /// The breadcrumb string. Pure and `static` so it is asserted directly.
    ///
    /// Returns the bare filename when the document is outside the vault (or
    /// there is no vault): a relative path that is not actually relative to
    /// anything would be a fiction, and an absolute one would be too long to
    /// read in a single line.
    static func breadcrumb(for url: URL, root: URL?) -> String {
        let name = url.lastPathComponent
        guard let root else { return name }
        let canonicalRoot = VaultIndexCoordinator.canonical(root)
        let canonical = VaultIndexCoordinator.canonical(url)
        let rootParts = canonicalRoot.pathComponents
        let parts = canonical.pathComponents
        guard parts.count > rootParts.count,
              Array(parts.prefix(rootParts.count)) == rootParts else { return name }
        // The vault's own folder name leads, so the crumb reads as a place
        // rather than as a bare path fragment.
        return ([canonicalRoot.lastPathComponent] + parts.dropFirst(rootParts.count))
            .joined(separator: " ▸ ")
    }
}

/// Drives the header's relative "Saved" wording without a permanent timer.
///
/// Wakes once after five seconds and once after a minute, then STOPS. A
/// repeating ticker would redraw the header forever for a label that stops
/// changing after a minute — and a redraw per second on the document pane is
/// exactly the class of cost `OutlineRefreshDebouncer` was written to remove.
enum RelativeClock {
    static func tick(_ update: @escaping @MainActor (Date) -> Void) async {
        for delay in [UInt64(5), UInt64(55)] {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { update(Date()) }
        }
    }
}
