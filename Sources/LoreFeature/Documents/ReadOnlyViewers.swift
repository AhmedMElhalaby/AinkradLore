import SwiftUI
import AppKit
import QuickLookUI
import AinkradAppKit

/// QuickLook preview of an arbitrary file.
///
/// `QLPreviewView` is the only renderer in the app that handles formats Lore
/// will never model itself — `.pages`, `.key`, `.numbers`, images, archives —
/// which is exactly what makes `AttachmentEngine` viable as a last resort.
@MainActor
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Reassigning an unchanged item restarts the preview and flickers.
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }
}

/// What a viewer shows when the document cannot be rendered at all.
///
/// The failure rule: never a crash, never a blank pane. The user gets the
/// filename, the reason, and the one action that always works.
@MainActor
struct DocumentErrorCard: View {
    let url: URL
    let message: String
    let theme: HostTheme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(theme.tokens.foreground.opacity(0.7))
            Text(url.lastPathComponent)
                .font(.headline)
                .foregroundStyle(theme.tokens.foreground)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tokens.background)
    }
}
