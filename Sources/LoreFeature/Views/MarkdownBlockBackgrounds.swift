import AppKit
import SwiftUI
import AinkradAppKit

/// Block decoration that is DRAWN, not attributed.
///
/// `.backgroundColor` is a per-glyph attribute, so a fenced block whose lines
/// differ in length gets a ragged right edge — a staircase, not a panel. That
/// raggedness is a large part of why the M2a editor read as "messed up". The
/// same applies to a blockquote: an indent alone does not say "quote", and the
/// bar that does say it exists between the text and the margin, where no
/// character lives.
///
/// Drawing is display-only by construction: nothing here touches the text
/// storage's string, and nothing here adds an attribute. The regions are
/// derived from style spans by the caller and handed over as plain ranges.
enum MarkdownBlockBackgrounds {

    /// What a region looks like, which is all the drawing needs to know.
    enum Kind: Equatable {
        /// A full-width panel behind a fenced code block.
        case codePanel
        /// A vertical bar in the left margin of a blockquote.
        case quoteBar
        /// The substitute for a COLLAPSED list marker, drawn in the gutter to
        /// the left of the item's text: `•` for `-`/`*`/`+`, and the item's own
        /// ordinal for a numbered list.
        ///
        /// Lists were the one construct that got its marker hidden with nothing
        /// put back, so an unfocused ordered list lost its numbering entirely.
        /// The associated value is what to DRAW, never what the document says —
        /// the source text is untouched, as everywhere else here.
        case listMarker(String)
        /// A tinted panel plus a coloured bar behind an Obsidian callout, and
        /// the icon and heading drawn on its first line.
        ///
        /// One case rather than three because all four parts share the callout's
        /// hue and its geometry, and splitting them would mean deriving the same
        /// rect three times and hoping the answers agreed.
        ///
        /// `title` is what to DRAW beside the icon: `nil` when the author wrote
        /// their own — that text is real, is in the document, and is styled as
        /// `.calloutTitle` — and the type's name when they did not, since a
        /// callout whose `[!note]` has collapsed would otherwise show an empty
        /// heading line.
        /// `marker` is the `[!type]` declaration's range, and the icon and
        /// heading are drawn only while it is COLLAPSED.
        ///
        /// Measured at draw time rather than stored, and that is the whole
        /// point: `blockBackgrounds` is rebuilt only on a full render, while
        /// reveal changes on every caret move. A stored flag therefore goes
        /// stale the instant the caret enters the callout, and the icon and
        /// heading get painted on top of the `> [!note]` the reader can now
        /// see — the overlap Ahmed photographed on 2026-08-17. `listMarker`
        /// has always decided this the same way, from geometry, which
        /// self-corrects because the geometry IS the reveal state.
        case callout(MarkdownCallout.Kind, title: String?, marker: NSRange)
    }

    /// A stretch of text to decorate. UTF-16, into the view's own string.
    struct Region: Equatable {
        let kind: Kind
        let range: NSRange
    }

    /// The two colours, resolved from the host theme.
    ///
    /// Neither is an accent: after Task 6 accent means "you can click this".
    /// A code panel is a surface, and a quote bar is quiet foreground.
    struct Palette: Equatable {
        let codePanel: NSColor
        let quoteBar: NSColor
        /// A list marker is quiet foreground too — it is punctuation, not a
        /// control, so it must not read as clickable.
        let listMarker: NSColor
        /// Kept so a callout's tint can be derived per KIND at draw time.
        /// Thirteen callout types would otherwise mean thirteen stored colours
        /// resolved for every document, almost all of them never used.
        let tokens: HostThemeTokens

        init(tokens: HostThemeTokens) {
            self.tokens = tokens
            codePanel = NSColor(tokens.surfaceElevated).withAlphaComponent(0.55)
            quoteBar = NSColor(tokens.foreground).withAlphaComponent(0.30)
            listMarker = NSColor(tokens.foreground).withAlphaComponent(0.55)
        }

        /// A callout's colour: its own hue, at a saturation and brightness that
        /// sit correctly on THIS theme's surface.
        ///
        /// The hue is fixed and the rest is derived, which is the whole trade —
        /// `danger` has to read as red in every theme or it is not saying
        /// danger, but a red picked for a dark surface glares on a light one.
        /// Brightness follows the theme's own foreground: a light foreground
        /// means a dark surface, so the tint is lightened to carry against it.
        ///
        /// `.quote` has no colour of its own and falls back to quiet
        /// foreground, exactly as an ordinary block quote does.
        static func calloutTint(_ kind: MarkdownCallout.Kind,
                                tokens: HostThemeTokens) -> NSColor {
            guard !kind.isNeutral else {
                return NSColor(tokens.foreground).withAlphaComponent(0.70)
            }
            let onDark = isDarkSurface(tokens: tokens)
            return NSColor(hue: kind.hue / 360,
                           saturation: onDark ? 0.55 : 0.75,
                           brightness: onDark ? 0.95 : 0.70,
                           alpha: 1)
        }

        /// Whether the editor is painting on a dark surface, judged from the
        /// FOREGROUND rather than from a theme name: a light foreground implies
        /// a dark background, and this works for any host theme without the
        /// tokens having to declare an appearance.
        static func isDarkSurface(tokens: HostThemeTokens) -> Bool {
            let foreground = NSColor(tokens.foreground).usingColorSpace(.sRGB)
            guard let foreground else { return true }
            let luminance = 0.299 * foreground.redComponent
                + 0.587 * foreground.greenComponent
                + 0.114 * foreground.blueComponent
            return luminance > 0.5
        }
    }

    /// The regions implied by a document's style spans.
    ///
    /// Spans arrive parent-first and may nest; only the two block kinds matter
    /// here, and each contributes exactly one region, so nesting cannot
    /// multiply the drawing.
    ///
    /// - Parameter window: the range whose ATTRIBUTES were applied, on an
    ///   over-cap document. Regions are intersected with it rather than merely
    ///   filtered by it, for two reasons: a panel must never be painted behind
    ///   text that was left unstyled, and asking the layout manager for the
    ///   bounding rect of a region far outside the viewport is exactly the work
    ///   that makes a long note stutter. `nil` means "the whole document was
    ///   styled", which is the ordinary case.
    /// - Parameter text: the document, needed only to read what a list marker
    ///   actually SAYS — `1.` and `7.` must not both draw as `1.`. `nil` (the
    ///   default, used by callers that only care about the block decorations)
    ///   emits no list markers rather than guessing at one.
    static func regions(for spans: [StyleSpan], length: Int,
                        limitedTo window: NSRange? = nil,
                        in text: NSString? = nil) -> [Region] {
        spans.compactMap { span in
            var r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= length else { return nil }

            let kind: Kind
            switch span.kind {
            case .codeBlock: kind = .codePanel
            case .blockQuote: kind = .quoteBar
            case .callout(let callout):
                // The heading to draw is decided HERE, where the text is in
                // hand, rather than at draw time: `draw` runs on every redraw
                // and must not be re-reading the document to find out whether
                // the author wrote a title.
                guard let text, NSMaxRange(r) <= text.length else { return nil }
                let header = MarkdownCallout.header(ofQuoteAt: span.range, in: text)
                let marker = header.map {
                    NSRange(location: $0.markerRange.lowerBound,
                            length: $0.markerRange.count)
                } ?? NSRange(location: span.range.lowerBound, length: 0)
                kind = .callout(callout,
                                title: header?.titleRange == nil
                                    ? callout.displayTitle : nil,
                                marker: marker)
            case .marker(of: .listBullet):
                // NOT clipped to the window: a marker is two or three
                // characters, so intersecting it would draw half a `10.`. It is
                // either wholly inside the styled window or it is not drawn.
                guard let text, NSMaxRange(r) <= text.length,
                      let glyph = listMarkerGlyph(for: text.substring(with: r))
                else { return nil }
                if let window,
                   NSIntersectionRange(r, window).length != r.length { return nil }
                return Region(kind: .listMarker(glyph), range: r)
            default: return nil
            }
            if let window {
                r = NSIntersectionRange(r, window)
                guard r.length > 0 else { return nil }
            }
            return Region(kind: kind, range: r)
        }
    }

    /// What a list marker's SOURCE draws as once collapsed.
    ///
    /// `- `, `* `, `+ ` become a real bullet; an ordinal keeps its own number
    /// and is normalised to a trailing `.` so a `1)` list and a `1.` list read
    /// alike. Anything else returns nil — the same "emit nothing rather than a
    /// guess" rule `MarkdownMarkers` follows, since a wrong glyph in the gutter
    /// is worse than none.
    static func listMarkerGlyph(for source: String) -> String? {
        let body = source.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if body == "-" || body == "*" || body == "+" { return "•" }
        let digits = body.dropLast()
        guard let last = body.last, last == "." || last == ")",
              !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return digits + "."
    }

    /// The left edge of the text column, in the text view's own coordinates.
    ///
    /// `textContainerOrigin` and nothing else. The rects this decoration is
    /// drawn against come from the LAYOUT, in container coordinates, and are
    /// offset by that same origin — so taking the panel's x from
    /// `textContainerInset.width` instead was a second coordinate source that
    /// happened to agree only while the column was not centred. Once
    /// `MarkdownEditorLayout` centres a capped column the two part company and
    /// every panel and bar detaches from its text.
    @MainActor
    static func columnX(in textView: NSTextView) -> CGFloat {
        textView.textContainerOrigin.x
    }

    /// The width of the text column — the container's, not the view's.
    ///
    /// A code panel is full width OF THE COLUMN. Using the view's bounds would
    /// make it overhang the text on a wide window by exactly the amount the
    /// measure cap took away.
    @MainActor
    static func columnWidth(in textView: NSTextView) -> CGFloat {
        if let container = textView.textContainer, container.size.width > 0 {
            return container.size.width
        }
        return max(0, textView.bounds.width - columnX(in: textView) * 2)
    }

    /// The corner radius of a code panel. Enough to read as a panel, little
    /// enough not to read as a button.
    static let cornerRadius: CGFloat = 5
    /// Width of a blockquote's bar.
    static let barWidth: CGFloat = 3
    /// The gap between a drawn list marker and the item's text.
    static let listMarkerGap: CGFloat = 5
    /// Below this rendered width a marker's source is COLLAPSED and its
    /// substitute must be drawn; at or above it the real characters are on
    /// screen — the caret is in the block — and drawing would double them.
    ///
    /// Geometry rather than bookkeeping, deliberately: reveal state changes on
    /// a caret move, which does not rebuild the regions, so a cached flag would
    /// go stale exactly when the user looked at it. The collapsed font is
    /// 0.01pt (see `MarkdownStyleRenderer.collapse`) and the revealed one is
    /// 14pt monospaced, so any threshold between them separates the two cases
    /// by three orders of magnitude.
    static let collapsedMarkerWidth: CGFloat = 2

    /// Paints `regions` into the current context, behind `textView`'s text.
    ///
    /// Called from `drawBackground(in:)`, so the text is drawn on top of
    /// whatever this leaves behind.
    @MainActor
    static func draw(_ regions: [Region], palette: Palette,
                     in textView: NSTextView, dirtyRect: NSRect) {
        guard !regions.isEmpty else { return }
        let origin = textView.textContainerOrigin
        // ONE coordinate source. `x` is the same `origin.x` the text rects are
        // offset by, so the decoration cannot drift away from the glyphs when
        // the column is capped and centred.
        let x = columnX(in: textView)
        let width = columnWidth(in: textView)
        for region in regions {
            if case .listMarker(let glyph) = region.kind {
                drawListMarker(glyph, at: region.range, columnX: x,
                               palette: palette, in: textView,
                               origin: origin, dirtyRect: dirtyRect)
                continue
            }
            if case .callout(let kind, let title, let marker) = region.kind {
                // Collapsed marker means the source is hidden, so the icon and
                // heading stand in for it. Visible marker means the caret is
                // on the header line and they must not be drawn at all.
                let drawsHeader = drawsCalloutHeader(marker: marker, in: textView)
                drawCallout(kind, title: drawsHeader ? title : nil,
                            drawsIcon: drawsHeader,
                            at: region.range, columnX: x,
                            columnWidth: width, tokens: palette.tokens,
                            in: textView, origin: origin, dirtyRect: dirtyRect)
                continue
            }
            var rect = boundingRect(of: region.range, in: textView)
            guard !rect.isNull, !rect.isEmpty else { continue }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            switch region.kind {
            case .codePanel:
                // Full width, deliberately: the panel is a property of the
                // BLOCK, not of the longest line in it.
                let panel = NSRect(x: x,
                                   y: rect.minY - 2,
                                   width: width,
                                   height: rect.height + 4)
                guard panel.intersects(dirtyRect) else { continue }
                palette.codePanel.setFill()
                NSBezierPath(roundedRect: panel, xRadius: cornerRadius,
                             yRadius: cornerRadius).fill()
            case .quoteBar:
                let bar = NSRect(x: x, y: rect.minY,
                                 width: barWidth, height: rect.height)
                guard bar.intersects(dirtyRect) else { continue }
                palette.quoteBar.setFill()
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2,
                             yRadius: barWidth / 2).fill()
            case .listMarker, .callout:
                break   // handled above, before the rect is taken
            }
        }
    }

    /// Draws a collapsed list marker's substitute in the gutter.
    ///
    /// Two rects, for two different questions. The MARKER's own rect answers
    /// "is it collapsed?" and gives the x the item's text starts at; the rect
    /// of the marker plus the first character of the item answers "where is
    /// this line, and how tall?", which a 0.01pt run cannot be trusted to.
    @MainActor
    private static func drawListMarker(_ glyph: String, at range: NSRange,
                                       columnX x: CGFloat, palette: Palette,
                                       in textView: NSTextView, origin: NSPoint,
                                       dirtyRect: NSRect) {
        let markerRect = boundingRect(of: range, in: textView)
        guard !markerRect.isNull else { return }
        guard markerRect.width < collapsedMarkerWidth else { return }

        let withContent = NSRange(location: range.location,
                                  length: min(range.length + 1,
                                              (textView.string as NSString).length
                                                - range.location))
        var line = boundingRect(of: withContent, in: textView)
        if line.isNull || line.height <= 0 { line = markerRect }
        guard line.height > 0 else { return }
        line = line.offsetBy(dx: origin.x, dy: origin.y)
        let textStart = markerRect.minX + origin.x

        let font = MarkdownStyleRenderer.baseFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: palette.listMarker
        ]
        let size = (glyph as NSString).size(withAttributes: attributes)
        // Right-aligned into the gutter, but never pushed out of the column: a
        // wide ordinal (`10.`) on a shallow indent runs out of gutter, and
        // clamping keeps it inside the measure instead of under the margin.
        let drawX = max(x, textStart - size.width - listMarkerGap)
        let rect = NSRect(x: drawX, y: line.midY - size.height / 2,
                          width: size.width, height: size.height)
        guard rect.intersects(dirtyRect) else { return }
        (glyph as NSString).draw(in: rect, withAttributes: attributes)
    }

    /// The union of the line rects `range` occupies, in TEXT CONTAINER
    /// coordinates, or a null rect if it occupies none.
    ///
    /// TextKit 2 first and by preference. Reading `NSTextView.layoutManager`
    /// on a TextKit 2 view silently downgrades the whole view to TextKit 1 —
    /// the same trap `MarkdownStyleRenderer.viewportWindow(of:)` documents — so
    /// that property is touched ONLY when `textLayoutManager` is already nil,
    /// which means the view is TextKit 1 and there is nothing left to downgrade.
    @MainActor
    private static func boundingRect(of range: NSRange, in textView: NSTextView) -> NSRect {
        if let layout = textView.textLayoutManager,
           let content = layout.textContentManager {
            let document = content.documentRange
            guard let start = content.location(document.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { return .null }
            var union = NSRect.null
            // No `ensureLayout(for:)`. Forcing layout from inside
            // `drawBackground(in:)` is a reentrancy hazard — drawing asks the
            // layout manager to change the thing being drawn — and it ran once
            // per region per draw, over ranges that were not clipped to the
            // viewport. Nothing is lost by dropping it: this is only ever
            // called while the visible text is being drawn, and text that is
            // being drawn is by definition laid out. A region that is entirely
            // off screen enumerates no segments, returns a null rect, and is
            // skipped — which is the desired outcome, reached without the work.
            layout.enumerateTextSegments(in: textRange, type: .standard,
                                         options: []) { _, frame, _, _ in
                if !frame.isEmpty { union = union.union(frame) }
                return true
            }
            return union
        }
        guard let manager = textView.layoutManager,
              let container = textView.textContainer else { return .null }
        let glyphs = manager.glyphRange(forCharacterRange: range,
                                        actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .null }
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    /// Whether a callout's icon and heading should be drawn: only while its
    /// `[!type]` declaration is collapsed.
    ///
    /// A zero-length marker (a callout whose header could not be re-read)
    /// answers `true`, which keeps the heading — the same direction every
    /// other guard in this file takes when it is unsure.
    @MainActor
    static func drawsCalloutHeader(marker: NSRange, in textView: NSTextView) -> Bool {
        guard marker.length > 0 else { return true }
        let rect = boundingRect(of: marker, in: textView)
        guard !rect.isNull else { return true }
        return rect.width < collapsedMarkerWidth
    }

    /// Draws a callout: the tinted panel, the coloured bar, the icon on the
    /// first line, and — only when the author wrote no title — the type's name.
    ///
    /// The icon and the name are DRAWN, never inserted. Inserting them would
    /// change the document text and with it every offset the index, the link
    /// graph and the MCP tools hold, which is the rule the whole of this file
    /// exists to honour.
    @MainActor
    private static func drawCallout(_ kind: MarkdownCallout.Kind, title: String?,
                                    drawsIcon: Bool,
                                    at range: NSRange, columnX x: CGFloat,
                                    columnWidth width: CGFloat,
                                    tokens: HostThemeTokens,
                                    in textView: NSTextView, origin: NSPoint,
                                    dirtyRect: NSRect) {
        var rect = boundingRect(of: range, in: textView)
        guard !rect.isNull, !rect.isEmpty else { return }
        rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        let tint = Palette.calloutTint(kind, tokens: tokens)

        let panel = NSRect(x: x, y: rect.minY - 2, width: width, height: rect.height + 4)
        guard panel.intersects(dirtyRect) else { return }
        // A wash, not a fill: the body text sits on this, and a callout that
        // out-shouts its own contents is decoration rather than emphasis.
        tint.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: panel, xRadius: cornerRadius,
                     yRadius: cornerRadius).fill()
        tint.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: panel.minY, width: barWidth,
                                         height: panel.height),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()

        // The FIRST LINE's rect, for the icon and the drawn name. Taken from
        // the first character rather than from the block, whose rect spans
        // every line in it.
        let firstCharacter = NSRange(location: range.location,
                                     length: min(1, range.length))
        var line = boundingRect(of: firstCharacter, in: textView)
        guard !line.isNull, line.height > 0 else { return }
        line = line.offsetBy(dx: origin.x, dy: origin.y)

        let font = MarkdownStyleRenderer.boldBaseFont
        let iconSize = font.pointSize
        let iconX = x + barWidth + 6
        if drawsIcon,
           let icon = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) {
            let configured = icon.withSymbolConfiguration(
                .init(pointSize: iconSize, weight: .semibold)) ?? icon
            let box = NSRect(x: iconX,
                             y: line.midY - iconSize / 2,
                             width: iconSize, height: iconSize)
            configured.isTemplate = true
            tint.set()
            configured.draw(in: box, from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
        }

        // The author's own title is real text and is styled as
        // `.calloutTitle`; only its absence is drawn over.
        guard let title else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: tint
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: iconX + iconSize + 6,
                                             y: line.midY - size.height / 2),
                                 withAttributes: attributes)
    }
}
