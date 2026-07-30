import SwiftUI
import AinkradAppKit

/// Backlinks and unresolved links for the open document.
///
/// Each backlink shows the line that contains the link: a bare list of
/// filenames is meaningfully less useful than seeing WHY something links here.
///
/// `backlinks(to:)` and `unresolvedLinks(from:)` hit SQLite, so they are never
/// called from `body` on every redraw. Both are computed once into `@State`
/// on `.onAppear` and recomputed on `.onChange(of: url)` — the only two
/// moments the answer can change from this view's perspective: opening the
/// panel fresh, and the user switching to a different open document. Any
/// change to the link graph itself (an edit elsewhere, a create-note) is
/// something THIS view triggers itself via `refresh()`, so those two
/// triggers are exhaustive for a view that owns no other input.
struct BacklinksPanel: View {
    @Bindable var store: LoreStore
    let url: URL
    let theme: HostTheme

    @State private var backlinks: [LoreStore.Backlink] = []
    @State private var unresolved: [UnresolvedLink] = []
    /// Why creating a note for an unresolved link failed, when it did.
    @State private var createFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            Button {
                store.setBacklinksPanelExpanded(!store.backlinksPanelExpanded)
            } label: {
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradIconGlyph(systemName: store.backlinksPanelExpanded
                        ? "chevron.down" : "chevron.right")
                    Text("Linked mentions (\(backlinks.count))")
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if store.backlinksPanelExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                        ForEach(backlinks) { link in
                            Button { store.open(url: link.row.path) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(link.row.title).bold().lineLimit(1)
                                    if !link.context.isEmpty {
                                        Text(link.context)
                                            .font(.caption)
                                            .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }

                        if !unresolved.isEmpty {
                            Text("Unresolved links").font(.caption)
                                .padding(.top, AinkradSpacing.xs)
                            ForEach(unresolved) { link in
                                HStack {
                                    Text(link.rawTarget).lineLimit(1)
                                    Spacer()
                                    AinkradButton(title: "Create note", style: .ghost) {
                                        create(link)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(AinkradSpacing.sm)
        .background(theme.tokens.background)
        // The same "Not done" sheet `DocumentPane` shows for a refused create.
        // This button used to swallow every failure in a `try?` and do nothing
        // visible at all.
        .sheet(isPresented: Binding(get: { createFailure != nil },
                                    set: { if !$0 { createFailure = nil } })) {
            MessageSheet(text: createFailure ?? "", theme: theme) { createFailure = nil }
        }
        .onAppear { refresh() }
        .onChange(of: url) { refresh() }
    }

    /// Creates the note an unresolved link names, through the store's single
    /// create-from-a-link path — the same one `DocumentPane` uses, so the two
    /// buttons cannot drift into behaving differently again.
    ///
    /// The syntax travels WITH the target, on the `UnresolvedLink` the index
    /// stored when it parsed the link — so a dead `[t](Design%20Doc.md)`
    /// creates `Design Doc.md` (which resolves it) rather than a junk file
    /// literally named `design%20doc.md` (which does not).
    private func create(_ link: UnresolvedLink) {
        let target = link.rawTarget
        do {
            try store.createAndOpenNote(forLinkTarget: target, syntax: link.syntax)
            // The target that was just created is no longer unresolved:
            // re-querying is what keeps this list honest.
            refresh()
        } catch {
            createFailure = "Couldn't create \"\(target)\": \(error.localizedDescription)"
        }
    }

    private func refresh() {
        backlinks = store.backlinks(to: url)
        unresolved = store.unresolvedLinks(from: url)
    }
}
