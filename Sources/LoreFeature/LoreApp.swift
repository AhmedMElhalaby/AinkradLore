import SwiftUI
import AinkradAppKit

public struct LoreApp: AinkradApp {
    public static let id = "lore"
    public static let displayName = "Lore"
    public static let icon = "book.closed"

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(
            Text("Hello from Lore 📖")
                .foregroundStyle(host.theme.tokens.accentPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(host.theme.tokens.background)
        )
    }

    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(Text("Lore settings"))
    }

    public static func chromeFill(host: HostServices) -> Color? { host.theme.tokens.background }
}
