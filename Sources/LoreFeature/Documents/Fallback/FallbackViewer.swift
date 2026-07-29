import SwiftUI
import AppKit
import AinkradAppKit

/// Shown when no engine claims a file, or when an engine's `load` threw.
///
/// The rule is degrade, never block: a vault containing `.xlsx` must not make
/// the file list lie about what is there, and a corrupt document must show a
/// reason rather than an empty editor the user might type into and "save".
struct FallbackViewer: View {
    let url: URL
    let error: Error?
    let theme: HostTheme

    var body: some View {
        AinkradEmptyState(
            icon: isUnsupported ? "doc.questionmark" : "exclamationmark.triangle",
            title: isUnsupported ? "Can't open this file yet" : "Couldn't open this file",
            message: message,
            actionTitle: "Reveal in Finder",
            action: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        .background(theme.tokens.background)
    }

    /// "No engine claims this" is a normal, non-alarming state; every other
    /// failure (unreadable bytes, permissions) is a real error and gets the
    /// warning treatment.
    private var isUnsupported: Bool {
        guard let error else { return true }
        if case EngineError.unsupported = error { return true }
        return false
    }

    private var message: String {
        if let error, !isUnsupported {
            return "\(url.lastPathComponent): \(error.localizedDescription)"
        }
        return "Lore has no editor for “\(url.lastPathComponent)” yet. "
             + "It stays in your vault and is safe to open elsewhere."
    }
}
