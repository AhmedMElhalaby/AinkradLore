import SwiftUI
import AinkradAppKit

public struct LoreApp: AinkradApp {
    public static let id = "lore"
    public static let displayName = "Lore"
    public static let icon = "book.closed"

    /// Keyed by the HOST-MINTED instance id, not by `ObjectIdentifier(host)`.
    ///
    /// The old key was the address of a box around a non-class-bound
    /// existential: reusable after free, so a new host could be handed the
    /// previous host's store — and this store owns an open SQLite connection
    /// and its file descriptor. Nothing was ever evicted either, so every store
    /// ever created lived for the process. `PluginInstanceStorage` fixes both:
    /// value keys that are never recycled, plus eviction in `teardown`.
    @MainActor private static let stores = PluginInstanceStorage<LoreStore>()

    /// The instance key for `host`.
    ///
    /// A generation-8 host mints one. A generation-7 host does not implement
    /// `PluginInstanceIdentity`, so fall back to the OLD per-host object
    /// identity rather than to one shared id — collapsing every legacy host
    /// onto a single key would make two hosts share a store, which is a
    /// regression rather than a fallback. The address-reuse hazard stays only
    /// on the legacy path, exactly as before, and is gone on generation 8.
    @MainActor private static func instance(of host: HostServices) -> PluginInstanceID {
        if let identified = host as? PluginInstanceIdentity { return identified.instanceID }
        let key = ObjectIdentifier(host as AnyObject)
        if let existing = legacyIDs[key] { return existing }
        let minted = PluginInstanceID()
        legacyIDs[key] = minted
        return minted
    }
    @MainActor private static var legacyIDs: [ObjectIdentifier: PluginInstanceID] = [:]

    @MainActor private static func store(for host: HostServices) -> LoreStore {
        stores.value(for: instance(of: host)) {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.ainkrad.plugin.lore", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return LoreStore(documents: host.documents, indexPath: dir.appendingPathComponent("index.sqlite"))
        }
    }

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(LoreRootView(store: store(for: host), theme: host.theme))
    }
    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(LoreSettingsView(store: store(for: host), theme: host.theme))
    }
    public static func chromeFill(host: HostServices) -> Color? { host.theme.tokens.background }
}

/// Generation 8: release this instance's resources when the host closes it.
/// Lore holds the heaviest of any plugin — an open SQLite database, its file
/// descriptor, and an FSEvents vault watcher — all of which used to outlive the
/// app for the rest of the process.
extension LoreApp: AinkradAppTeardown {
    public static func teardown(instance: PluginInstanceID) {
        stores.remove(instance)?.shutdown()
    }
}
