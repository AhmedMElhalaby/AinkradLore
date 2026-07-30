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

        init(tokens: HostThemeTokens) {
            codePanel = NSColor(tokens.surfaceElevated).withAlphaComponent(0.55)
            quoteBar = NSColor(tokens.foreground).withAlphaComponent(0.30)
        }
    }

    /// The regions implied by a document's style spans.
    ///
    /// Spans arrive parent-first and may nest; only the two block kinds matter
    /// here, and each contributes exactly one region, so nesting cannot
    /// multiply the drawing.
    static func regions(for spans: [StyleSpan], length: Int) -> [Region] {
        spans.compactMap { span in
            let kind: Kind
            switch span.kind {
            case .codeBlock: kind = .codePanel
            case .blockQuote: kind = .quoteBar
            default: return nil
            }
            let r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= length else { return nil }
            return Region(kind: kind, range: r)
        }
    }

    /// The corner radius of a code panel. Enough to read as a panel, little
    /// enough not to read as a button.
    static let cornerRadius: CGFloat = 5
    /// Width of a blockquote's bar.
    static let barWidth: CGFloat = 3

    /// Paints `regions` into the current context, behind `textView`'s text.
    ///
    /// Called from `drawBackground(in:)`, so the text is drawn on top of
    /// whatever this leaves behind.
    @MainActor
    static func draw(_ regions: [Region], palette: Palette,
                     in textView: NSTextView, dirtyRect: NSRect) {
        guard !regions.isEmpty else { return }
        let origin = textView.textContainerOrigin
        let inset = textView.textContainerInset.width
        for region in regions {
            var rect = boundingRect(of: region.range, in: textView)
            guard !rect.isNull, !rect.isEmpty else { continue }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            switch region.kind {
            case .codePanel:
                // Full width, deliberately: the panel is a property of the
                // BLOCK, not of the longest line in it.
                let panel = NSRect(x: inset,
                                   y: rect.minY - 2,
                                   width: max(0, textView.bounds.width - inset * 2),
                                   height: rect.height + 4)
                guard panel.intersects(dirtyRect) else { continue }
                palette.codePanel.setFill()
                NSBezierPath(roundedRect: panel, xRadius: cornerRadius,
                             yRadius: cornerRadius).fill()
            case .quoteBar:
                let bar = NSRect(x: inset, y: rect.minY,
                                 width: barWidth, height: rect.height)
                guard bar.intersects(dirtyRect) else { continue }
                palette.quoteBar.setFill()
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2,
                             yRadius: barWidth / 2).fill()
            }
        }
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
            layout.ensureLayout(for: textRange)
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
}
