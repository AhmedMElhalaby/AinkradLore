import SwiftUI
import AinkradAppKit

/// Routes one session to its engine's editor, and owns the banners that are
/// shared by every document type: read-only, save failure, and conflict.
struct DocumentPane: View {
    @Bindable var store: LoreStore
    let session: DocumentSession
    let theme: HostTheme
    /// The raw target of a Cmd-clicked link that resolved to nothing. Non-nil
    /// only while the "create it?" prompt is up — clicking a dead link must
    /// never create a file silently.
    @State private var unresolved: String?
    /// Why creating that note failed, when it did.
    @State private var createFailure: String?
    /// Handed back by the markdown editor via `registerScrollHandler` — the
    /// only channel `OutlineSection` has to reach an editor it is a SIBLING
    /// of, not a parent of. `nil` until the editor has appeared once.
    @State private var scrollHandler: ((Int) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if session.isReadOnly { readOnlyBanner }
            if session.conflict { conflictBanner }
            // A save error and a conflict are different situations with
            // different affordances, so they are different banners. Both can be
            // true at once only transiently; showing both is still honest.
            if let error = session.lastSaveError, !session.conflict { saveErrorBanner(error) }

            session.engine.makeEditor(
                EditorContext(theme: theme,
                              onChange: { session.markChanged() },
                              completions: { store.linkCompletions(matching: $0) },
                              openLink: { target in
                                  // `documentName` first: `openLink` funnels into
                                  // `LinkResolver.basename`, which strips a
                                  // `#fragment` but NOT an `|alias`, so
                                  // `[[Design|why]]` would look up "Design|why"
                                  // and never resolve.
                                  let name = LinkCompletionContext.documentName(of: target)
                                  if !store.openLink(name) { unresolved = name }
                              },
                              linkTarget: { store.linkTarget(for: $0) },
                              registerScrollHandler: { handler in scrollHandler = handler }))
                // The engines' editors seed their `@State` in `.onAppear` only,
                // and `resolveByReloading()` mutates the engine in place — so
                // without the generation in the identity the user clicks
                // "Reload" and the OLD text stays on screen. Changing the id
                // tears the editor down and builds a fresh one, which re-runs
                // `.onAppear` against the reloaded engine.
                .id("\(session.id)-\(session.reloadGeneration)")

            // Only markdown documents contribute to the link graph, or have
            // headings at all — plain-text and unclaimed documents would show
            // an empty panel, which is noise, not information.
            if let markdownEngine = session.engine as? MarkdownEngine {
                OutlineSection(store: store, outline: markdownEngine.indexPayload.outline,
                              theme: theme) { offset in scrollHandler?(offset) }
                    .frame(maxHeight: 200)
                BacklinksPanel(store: store, url: session.url, theme: theme)
                    .frame(maxHeight: 200)
            }
        }
        .background(theme.tokens.background)
        .alert("Create this note?",
               isPresented: Binding(get: { unresolved != nil },
                                    set: { if !$0 { unresolved = nil } })) {
            Button("Cancel", role: .cancel) { unresolved = nil }
            Button("Create") {
                if let target = unresolved { createUnresolved(target) }
                unresolved = nil
            }
        } message: {
            Text("\"\(unresolved ?? "")\" doesn't exist in this vault yet.")
        }
        // The same "Not done" sheet the sidebar uses for a refused trash. A
        // Create button that silently does nothing on a failed write is worse
        // than no button.
        .sheet(isPresented: Binding(get: { createFailure != nil },
                                    set: { if !$0 { createFailure = nil } })) {
            MessageSheet(text: createFailure ?? "", theme: theme) { createFailure = nil }
        }
    }

    /// Creates the note this dead link names, via the store's single
    /// create-from-a-link path — see `LoreStore.createAndOpenNote(forLinkTarget:)`,
    /// which owns the alias/fragment stripping and the folder split. The view's
    /// only job is to show a failure instead of swallowing it.
    ///
    /// `.wikilink` is not a guess: this alert is reachable only from
    /// `MarkdownEditor.Coordinator.openLink(atUTF16:)`, whose target comes from
    /// `LinkCompletionContext.target(in:at:)` — a scanner that recognises `[[`
    /// and `]]` and nothing else. A markdown link is not clickable here, so no
    /// percent-decoding applies.
    private func createUnresolved(_ target: String) {
        do {
            try store.createAndOpenNote(forLinkTarget: target, syntax: .wikilink)
        } catch {
            createFailure = "Couldn't create \"\(target)\": \(error.localizedDescription)"
        }
    }

    /// Persistent and non-alarming: this file is open, readable and searchable,
    /// it simply cannot be written back. A user typing into a document that
    /// will never save, with no indication, is the failure this prevents.
    private var readOnlyBanner: some View {
        banner(icon: "lock", tint: theme.tokens.accentTertiary) {
            Text("Read-only: this file isn't valid UTF-8, so Lore can't write it back "
                 + "without destroying data. Edits here won't be saved.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Three resolutions, all reachable, none destructive by default. The old
    /// dialog offered only "load from disk" and treated dismissal as
    /// "overwrite", which meant the safe choice was the one you got by
    /// accident.
    private var conflictBanner: some View {
        banner(icon: "exclamationmark.triangle", tint: theme.tokens.accentSecondary) {
            Text("This document changed on disk outside Lore.")
                .frame(maxWidth: .infinity, alignment: .leading)
            AinkradButton(title: "Reload from disk", style: .secondary) {
                try? session.resolveByReloading()
            }
            // Labelled to say where editing continues: this tab adopts the copy.
            AinkradButton(title: "Save my copy & edit it", style: .secondary) {
                try? session.resolveBySavingCopy()
            }
            AinkradButton(title: "Overwrite disk", style: .ghost) {
                try? session.resolveByOverwriting()
            }
        }
    }

    /// Disk full, permissions, a read-only volume. There is no resolution to
    /// offer — the only requirement is that it stops being invisible.
    private func saveErrorBanner(_ error: Error) -> some View {
        banner(icon: "exclamationmark.circle", tint: theme.tokens.accentPrimary) {
            Text("Couldn't save this document: \(error.localizedDescription)")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func banner<Content: View>(icon: String, tint: Color,
                                       @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: AinkradSpacing.sm) {
            AinkradIconGlyph(systemName: icon)
            content()
        }
        .padding(AinkradSpacing.sm)
        .background(tint.opacity(0.15))
    }
}
