import Foundation

public struct Note: Identifiable, Equatable, Sendable {
    public let path: URL
    public var id: String
    public var title: String
    public var tags: [String]
    public var created: Date
    public var updated: Date
    public var body: String

    public init(path: URL, id: String, title: String, tags: [String],
                created: Date, updated: Date, body: String) {
        self.path = path; self.id = id; self.title = title; self.tags = tags
        self.created = created; self.updated = updated; self.body = body
    }
}
