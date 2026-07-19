import SwiftUI
import AppKit

struct LoreSettingsView: View {
    @Bindable var store: LoreStore

    var body: some View {
        Form {
            LabeledContent("Vault folder") {
                HStack {
                    Text(store.vaultRoot?.path ?? "None selected").lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: pickFolder)
                }
            }
            Button("Rebuild index") { try? store.rebuild() }
        }
        .padding()
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { try? store.setVaultRoot(url) }
    }
}
