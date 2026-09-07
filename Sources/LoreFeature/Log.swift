import os

/// This repo's `os.Logger` categories, all under the shared Ainkrad
/// subsystem so a user's whole install filters as one stream in Console.app.
///
/// The subsystem is spelled out here rather than taken from the SDK's
/// `AinkradLog` because this repo's AinkradAppKit pin (6cd1599) predates
/// that type. Switch to `AinkradLog.logger(app:area:)` whenever this pin
/// next moves forward.
enum Log {
    private static let subsystem = "com.ainkrad.app"
    static let store = Logger(subsystem: subsystem, category: "lore.store")
    static let editor = Logger(subsystem: subsystem, category: "lore.editor")
    static let import_ = Logger(subsystem: subsystem, category: "lore.import")
    static let search = Logger(subsystem: subsystem, category: "lore.search")
    static let watcher = Logger(subsystem: subsystem, category: "lore.watcher")
}
