import SwiftUI
import AppKit
import AinkradAppKit

public struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let tokens: HostThemeTokens

    public init(text: Binding<String>, tokens: HostThemeTokens) {
        self._text = text; self.tokens = tokens
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(tokens.background)
        tv.textContainerInset = NSSize(width: 16, height: 16)
        context.coordinator.textView = tv
        tv.string = text
        context.coordinator.applyStyles()
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text { tv.string = text; context.coordinator.applyStyles() }
        tv.backgroundColor = NSColor(tokens.background)
        context.coordinator.tokens = tokens
        context.coordinator.applyStyles()
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text, tokens: tokens) }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var tokens: HostThemeTokens
        weak var textView: NSTextView?

        init(text: Binding<String>, tokens: HostThemeTokens) { self.text = text; self.tokens = tokens }

        public func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            text.wrappedValue = tv.string
            applyStyles()
        }

        func applyStyles() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            storage.beginEditing()
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor(tokens.foreground)
            ], range: full)
            for span in MarkdownStyler.spans(in: tv.string) {
                let r = NSRange(location: span.range.lowerBound, length: span.range.count)
                switch span.kind {
                case .heading(let lvl):
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(
                        ofSize: max(14, 26 - CGFloat(lvl) * 2)), range: r)
                    storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)
                case .bold:
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: r)
                case .italic:
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(
                        .systemFont(ofSize: 14), toHaveTrait: .italicFontMask), range: r)
                case .code:
                    storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentSecondary), range: r)
                case .link:
                    storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                case .checkbox:
                    storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentTertiary), range: r)
                }
            }
            storage.endEditing()
        }
    }
}
