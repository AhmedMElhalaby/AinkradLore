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

    @MainActor func makeEditor(_ ctx: EditorContext) -> AnyView
}
