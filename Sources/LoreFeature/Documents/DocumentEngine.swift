import SwiftUI

/// One document type: how to detect it, load it, save it, index it, and edit it.
///
/// Class-bound so a loaded document is a reference the session mutates in place
/// and the editor view binds to.
public protocol DocumentEngine: AnyObject {
    /// Stable identifier, stored in the index's `type` column.
    static var identifier: String { get }

    /// True when this engine claims `url`. Must be mutually exclusive with
    /// every other registered engine — `EngineConformanceTests` enforces it.
    static func canOpen(_ url: URL) -> Bool

    static func load(_ url: URL) throws -> Self

    func save(to url: URL) throws

    var indexPayload: IndexPayload { get }

    /// Just the title, without building the rest of the payload.
    ///
    /// `DocumentSession` caches the title and refreshes it on load, save,
    /// reload and copy-adoption — four places that only ever wanted one
    /// `String`. Routing them through `indexPayload` made each one pay for a
    /// full markdown parse (outline) plus a link scan, and `save()` paid it a
    /// SECOND time immediately afterwards inside `indexDocument`. On the main
    /// actor, 500 ms after the user stops typing.
    ///
    /// Defaulted to `indexPayload.title` so no engine is forced to implement
    /// it; an engine whose title is cheap (both of them, as it happens)
    /// overrides and the parse disappears.
    var indexTitle: String { get }

    @MainActor func makeEditor(_ ctx: EditorContext) -> AnyView
}

public extension DocumentEngine {
    var indexTitle: String { indexPayload.title }
}
