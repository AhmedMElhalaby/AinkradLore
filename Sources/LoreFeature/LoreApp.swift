import SwiftUI
import AinkradAppKit

public struct LoreApp: AinkradApp {
    public static let id = "lore"
    public static let displayName = "Lore"
    public static let icon = "book.closed"

    @MainActor private static var stores: [ObjectIdentifier: LoreStore] = [:]

    @MainActor private static func store(for host: HostServices) -> LoreStore {
        let key = ObjectIdentifier(host as AnyObject)
        if let s = stores[key] { return s }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ainkrad.plugin.lore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = LoreStore(documents: host.documents, indexPath: dir.appendingPathComponent("index.sqlite"))
        stores[key] = s
        return s
    }

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(LoreRootView(store: store(for: host), theme: host.theme))
    }
    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(LoreSettingsView(store: store(for: host)))
    }
    public static func chromeFill(host: HostServices) -> Color? { host.theme.tokens.background }
}
