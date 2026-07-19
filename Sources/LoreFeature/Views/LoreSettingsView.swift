import SwiftUI
import AppKit
import AinkradAppKit

struct LoreSettingsView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @Environment(\.ainkradTypography) private var typo

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

            if !store.subfolders.isEmpty {
                AinkradFormRow(title: "Default new-note folder",
                               help: "Where ⌘N quick-capture saves new notes.") {
                    AinkradSelect(items: [""] + store.subfolders,
                                  selection: defaultFolderBinding,
                                  label: { $0.isEmpty ? "Vault root" : $0 })
                }
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

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { try? store.setVaultRoot(url) }
    }
}
