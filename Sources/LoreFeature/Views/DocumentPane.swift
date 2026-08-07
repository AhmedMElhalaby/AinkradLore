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

    /// The current document's outline, cached rather than read off
    /// `MarkdownEngine.outline` inside `body` — `outline` is a full AST parse,
    /// and `body` re-evaluates on every unrelated redraw (a banner appearing,
    /// a theme change). Same reasoning `BacklinksPanel` already applies to
    /// `backlinks`/`unresolved`. `@State`, not `let`, because a reference type
    /// (`OutlineRefreshDebouncer`) is fine to hold across redraws but this
    /// needs SwiftUI to redraw ON assignment.
    @State private var outline: [OutlineEntry] = []
    /// Debounces the ONE trigger that can fire many times per second: typing.
    /// `onAppear` / `.onChange(of: session.url)` / `.onChange(of:
    /// session.reloadGeneration)` each fire at most once per real event and
    /// refresh immediately; a keystroke goes through this instead, exactly
    /// the way `MarkdownEditor.Coordinator.scheduleParse` debounces its own
    /// re-parse — an outline refresh is the same class of cost (a full
    /// `Document(parsing:)`) and firing it on every keystroke, on the main
    /// actor, inside a SwiftUI `body`, is the exact regression Task 6 spent a
    /// task removing from the styling path.
    @State private var outlineDebouncer = OutlineRefreshDebouncer()

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
                              onChange: {
                                  session.markChanged()
                                  // Debounced — see `outlineDebouncer`'s doc
                                  // comment. `refreshOutline` is cheap to call
                                  // repeatedly; the debouncer just makes sure
                                  // only the LAST call in a typing burst runs.
                                  outlineDebouncer.schedule(after: 0.3) { refreshOutline() }
                              },
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
                              registerScrollHandler: { handler in scrollHandler = handler },
                              isReadOnly: session.isReadOnly))
                // The engines' editors seed their `@State` in `.onAppear` only,
                // and `resolveByReloading()` mutates the engine in place — so
                // without the generation in the identity the user clicks
                // "Reload" and the OLD text stays on screen. Changing the id
                // tears the editor down and builds a fresh one, which re-runs
                // `.onAppear` against the reloaded engine.
                .id("\(session.id)-\(session.reloadGeneration)")

            // Only markdown documents contribute to the link graph — plain-
            // text and attachment documents would show an empty panel, which
            // is noise, not information.
            if session.engine is MarkdownEngine {
                // Gated on the CACHED outline being non-empty, not merely on
                // the document being markdown: a markdown note with no
                // headings yet is exactly as noise-free a case as a
                // plain-text file, and showing an empty "Outline (0)" here
                // would contradict the reasoning that already justifies
                // gating `BacklinksPanel` on the engine type in the first
                // place — an empty panel either way is noise.
                if !outline.isEmpty {
                    OutlineSection(store: store, outline: outline,
                                  theme: theme) { offset in scrollHandler?(offset) }
                        .frame(maxHeight: 200)
                }
                BacklinksPanel(store: store, url: session.url, theme: theme)
                    .frame(maxHeight: 200)
            }
        }
        .background(theme.tokens.background)
        .onAppear { refreshOutline() }
        // Same two triggers `BacklinksPanel` uses for the reasons it already
        // documents (a rename changes `url` without changing `session.id`),
        // plus `reloadGeneration`: "Reload from disk" replaces the engine's
        // note in place without either of those changing, and the outline
        // must not keep showing headings from the text that was just
        // discarded.
        .onChange(of: session.url) { refreshOutline() }
        .onChange(of: session.reloadGeneration) { refreshOutline() }
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

    /// Re-derives `outline` from the engine's own `outline` accessor — a
    /// heading-only parse, NOT `indexPayload` (which also runs a link scan
    /// this view has no use for). `nil` for a non-markdown engine, same as
    /// the gating above.
    ///
    /// Staleness between refreshes: a click that lands mid-debounce scrolls
    /// to an offset computed from the text as it was UP TO 0.3s ago. Purely
    /// additive edits above the clicked heading shift where it visually sits
    /// without changing the offset math (headings below an edit still start
    /// where they started, relative to the edit's own position) — the only
    /// case that can go visibly wrong is the debounce window closing between
    /// an edit that changes a HEADING'S OWN text and a click on the OLD
    /// label the user is still looking at. `MarkdownEditor.Coordinator.
    /// scrollToOffset` clamps to `[0, length]`, so a stale offset can select
    /// the wrong place; it can never crash or select out of bounds.
    private func refreshOutline() {
        outline = (session.engine as? MarkdownEngine)?.outline ?? []
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

/// Coalesces a burst of `ctx.onChange` calls (one per keystroke) into a
/// single refresh, exactly the shape `MarkdownEditor.Coordinator.
/// scheduleParse` already uses for the same reason: only the LAST call in a
/// burst should do the expensive work.
///
/// A class, not a struct, so `DocumentPane`'s `@State` can hold the SAME
/// instance — and therefore the same in-flight `Timer` — across every body
/// re-evaluation between keystrokes; a struct copy would lose the pending
/// timer on every redraw and never coalesce anything.
@MainActor
final class OutlineRefreshDebouncer {
    private var timer: Timer?

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer = t
        // `.common`, matching `Coordinator.scheduleParse`: the refresh must
        // still land while the user is scrolling or holding a menu open.
        RunLoop.main.add(t, forMode: .common)
    }
}
