import AppKit

// Container geometry and the off-actor parse pipeline for `MarkdownEditor`.
// Moved out of `MarkdownEditorReveal.swift`, which was over the 500-line
// cap — that file keeps the reveal/render machinery (`applyStyles`,
// `renderStyles`, `revealForSelectionChange`, `restyleBlock`); this one is
// everything downstream of "the text container's width changed" or "the
// debounce fired".
extension MarkdownEditor.Coordinator {

    // MARK: - Container geometry

    /// Re-applies both the inset and the container's own width for a view
    /// `width` points wide.
    ///
    /// Called on every width change, because BOTH are a function of the
    /// view's width: the inset would keep the margins it was born with and
    /// drift off-centre as the window resizes, and — the bug this method used
    /// to have — the container's width would stay pinned at the theme's
    /// measure regardless of how narrow the pane got, leaving text wider than
    /// the visible view with no horizontal scroller to reach it. The two are
    /// applied together, from the one function that owns both
    /// (`containerInset`/`containerWidth`), so they cannot drift apart again.
    func applyContainerGeometry(forWidth width: CGFloat) {
        guard let tv = textView else { return }
        let theme = MarkdownTheme(tokens: tokens, settings: settings)
        let inset = MarkdownEditorLayout.containerInset(forViewWidth: width, theme: theme)
        let containerWidth = MarkdownEditorLayout.containerWidth(forViewWidth: width, theme: theme)
        let insetChanged = tv.textContainerInset != inset
        let widthChanged = tv.textContainer?.size.width != containerWidth
        guard insetChanged || widthChanged else { return }
        tv.textContainerInset = inset
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        // The drawn decoration is positioned from the container, so it has to
        // be repainted when the container moves.
        tv.needsDisplay = true
        // Every transcluded embed's measured height is a function of THIS
        // width — see `TransclusionMeasurement`. A stale height self-corrects
        // on the very next render (the geometry travels with the number), so
        // dropping it here is purely an optimisation: it stops the next pass
        // from carrying around a measurement it already knows it cannot use,
        // rather than discovering that one geometry check at a time.
        transclusionCache.invalidateMeasurements()
    }

    // MARK: - Live transclusion updates

    /// Compares every currently-embedded transclusion target's on-disk mtime
    /// against what the last check saw, and invalidates the cache for any
    /// that changed.
    ///
    /// Exists because `applyStyles()`'s redundant-redraw guard
    /// (`isRenderStale`) compares only `tokens` and this document's own text
    /// — neither of which changes when a DIFFERENT file, embedded here via
    /// `![[…]]`, is edited on disk (in Obsidian, or the same file open in
    /// another split pane). Without this check, such an edit would sit
    /// invisible until some unrelated change to THIS document happened to
    /// force a render.
    ///
    /// `cache.invalidate(path:)` is called proactively rather than relying on
    /// `TransclusionKey`'s mtime alone: that key is already self-correcting
    /// for an ordinary mtime bump (a new mtime is simply a new key — see
    /// `TransclusionMeasurement`'s doc comment for the same property on
    /// measurements), but a same-second edit on a filesystem with coarse
    /// mtime resolution can leave the mtime unchanged (see
    /// `DocumentSession.baseline`'s doc comment on the identical limit), and
    /// only an explicit invalidation catches that case.
    ///
    /// Called from `applyStyles()`, on every call — including ones the
    /// redundant-redraw guard would otherwise skip — so it is cheap by
    /// construction: a handful of `stat` calls for a document's (usually
    /// zero, rarely more than a few) transcluded targets, never a re-parse or
    /// a re-measure by itself.
    /// - Returns: whether any target changed, so `applyStyles()` knows to
    ///   force a render even when nothing else about this document did.
    @discardableResult
    func detectExternalTransclusionChanges() -> Bool {
        var changed = false
        var seen: Set<URL> = []
        for span in styleCache.spans {
            guard case .embed(let target, _) = span.kind else { continue }
            guard case .transclusion(let url) = EmbedRendering.kind(for: resolveEmbedTarget(target))
            else { continue }
            seen.insert(url)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = (attributes?[.modificationDate] as? Date) ?? .distantPast
            if let known = embeddedTargetMTimes[url], known != mtime {
                transclusionCache.invalidate(path: url)
                changed = true
            }
            embeddedTargetMTimes[url] = mtime
        }
        // Targets no longer embedded (the `![[…]]` was removed or edited to
        // point elsewhere) are dropped, so a later re-embed of the same path
        // is compared against a fresh baseline rather than one from before it
        // was removed.
        if embeddedTargetMTimes.count != seen.count {
            embeddedTargetMTimes = embeddedTargetMTimes.filter { seen.contains($0.key) }
        }
        return changed
    }

    // MARK: - Parsing

    /// Re-arms the debounce. Only its firing parses, so a burst of typing
    /// costs one parse rather than one per character.
    func scheduleParse() {
        parseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.parseDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.parseNow() }
        }
        parseTimer = timer
        // `.common` so the parse still lands while the user is scrolling or
        // holding a menu open, rather than after they stop.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Parses OFF the main actor and applies the result back on it.
    ///
    /// This used to be a synchronous parse on the main actor, called from a
    /// main-run-loop timer. On a large note that is measured in whole
    /// seconds, and a main-actor second is not lag — it is a beachball, once
    /// per pause in typing. The parse itself is pure (`derive` touches no
    /// AppKit and no editor state), so the only thing that must stay on the
    /// main actor is applying the answer.
    ///
    /// Two guards keep a slow parse from styling the wrong characters:
    ///
    /// 1. `generation` — a newer parse having been started makes this one's
    ///    result garbage, even if the text looks right.
    /// 2. the SNAPSHOT check — the spans index `snapshot` and nothing else,
    ///    so they are installed only if the view still holds exactly that
    ///    string. This is the same identity rule `describes(_:)` encodes,
    ///    applied across the hop.
    ///
    /// When the text HAS moved on, nothing is applied and nothing is
    /// re-armed here: the edit that moved it went through `textDidChange`,
    /// which armed the debounce already.
    func parseNow() {
        // Invalidated, not merely dropped: `applyStyles` calls this DIRECTLY on
        // the open path, so there may be a debounce timer still armed, and a
        // released-but-live `Timer` would fire into a parse that has already
        // been launched.
        parseTimer?.invalidate()
        parseTimer = nil
        guard let tv = textView else { return }
        let snapshot = tv.string
        guard styleCache.isStale || !styleCache.describes(snapshot) else { return }
        parseGeneration += 1
        let generation = parseGeneration
        Task.detached(priority: .userInitiated) {
            let derived = MarkdownStyleCache.derive(snapshot)
            await MainActor.run { [weak self] in
                self?.applyParsed(derived, of: snapshot, generation: generation)
            }
        }
    }

    private func applyParsed(_ derived: MarkdownStyleCache.Derived,
                             of snapshot: String, generation: Int) {
        guard generation == parseGeneration,
              let tv = textView, tv.string == snapshot else { return }
        styleCache.adopt(derived, for: snapshot)
        renderStyles()
    }

    /// In viewport mode the styled range follows the scroll, so scrolling
    /// has to re-render — but only when the window actually moved, since
    /// this fires continuously during a drag.
    func restyleForViewportIfNeeded() {
        guard styleCache.isOverViewportCap, let tv = textView else { return }
        let window = MarkdownStyleRenderer.viewportWindow(of: tv)
        if let last = lastViewportWindow, NSEqualRanges(last, window) { return }
        renderStyles()
    }
}
