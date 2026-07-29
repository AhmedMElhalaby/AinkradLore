import Foundation

/// Ordered engine lookup. Order is significance order: the first engine whose
/// `canOpen` returns true wins. Engines are required to be mutually exclusive,
/// so order is a tie-break that should never actually be needed — it exists so
/// a bug produces deterministic behavior rather than a coin flip.
public enum EngineRegistry {
    public static let engines: [any DocumentEngine.Type] = [
        MarkdownEngine.self,
        PlainTextEngine.self,
    ]

    public static func engine(for url: URL) -> (any DocumentEngine.Type)? {
        engines.first { $0.canOpen(url) }
    }

    /// Loads `url` with whichever engine claims it.
    /// Throws `EngineError.unsupported` when none does — the caller renders the
    /// read-only fallback viewer rather than pretending the file is not there.
    public static func load(_ url: URL) throws -> any DocumentEngine {
        guard let engine = engine(for: url) else { throw EngineError.unsupported(url) }
        return try engine.load(url)
    }
}

public enum EngineError: Error, Equatable {
    case unsupported(URL)
}
