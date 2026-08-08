import SwiftUI
import AppKit
import AinkradAppKit

struct LoreSettingsView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @Environment(\.ainkradTypography) private var typo
    /// Why the last vault choice did not take. Nil when nothing has failed.
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.lg) {
            AinkradFormRow(title: "Vault folder",
                           help: "The folder of markdown files Lore reads and writes.") {
                HStack(spacing: AinkradSpacing.sm) {
                    Text(store.vaultRoot?.path ?? "None selected")
                        .font(AinkradFontResolver.font(.mono, typography: typo))
                        .foregroundStyle(theme.tokens.foreground.opacity(0.8))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AinkradButton(title: "Choose…", style: .secondary, action: pickFolder)
                }
            }

            if let failure {
                Text(failure)
                    .foregroundStyle(theme.tokens.accentPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.subfolders.isEmpty {
                AinkradFormRow(title: "Default new-note folder",
                               help: "Where ⌘N quick-capture saves new notes.") {
                    AinkradSelect(items: [""] + store.subfolders,
                                  selection: defaultFolderBinding,
                                  label: { $0.isEmpty ? "Vault root" : $0 })
                }
            }

            AinkradFormRow(title: "Show all files",
                           help: "Show every file in the sidebar, including "
                               + "attachments Lore can't render inline (zip "
                               + "archives, credentials files, other "
                               + "binaries). Off by default so the sidebar "
                               + "stays a list of documents. Files stay fully "
                               + "indexed, linkable and openable either way —"
                               + " this only changes what the browse list "
                               + "draws.") {
                AinkradToggle(isOn: showAllFilesBinding)
            }

            AinkradFormRow(title: "Index",
                           help: "Rebuild the search index from the files on disk.") {
                AinkradButton(title: "Rebuild index", style: .ghost) { try? store.rebuild() }
            }
        }
        .padding(AinkradSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.ainkradTheme, theme.tokens)
    }

    private var defaultFolderBinding: Binding<String> {
        Binding(get: { store.defaultNoteFolder },
                set: { store.setDefaultNoteFolder($0) })
    }

    private var showAllFilesBinding: Binding<Bool> {
        Binding(get: { store.showAllFiles },
                set: { store.setShowAllFiles($0) })
    }

    /// Shares `SidebarOperations`' picker so settings and the first-run empty
    /// state cannot drift apart, and so a failure here is reported rather than
    /// swallowed. This was `try? store.setVaultRoot(url)`: a vault that could
    /// not be bookmarked or indexed left the row still reading "None selected"
    /// with nothing said about why.
    private func pickFolder() {
        let ops = SidebarOperations(store: store)
        ops.beginChooseVault()
        failure = ops.message
    }
}
