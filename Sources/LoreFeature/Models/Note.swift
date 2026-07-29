import Foundation

public struct FrontmatterPair: Equatable, Sendable {
    public let key: String
    public let rawValue: String
    public init(key: String, rawValue: String) { self.key = key; self.rawValue = rawValue }
}

public struct Note: Identifiable, Equatable, Sendable {
    public let path: URL
    public var id: String
    public var title: String
    public var tags: [String]
    public var created: Date
    public var updated: Date
    public var body: String
    public var extra: [FrontmatterPair]

    public init(path: URL, id: String, title: String, tags: [String],
                created: Date, updated: Date, body: String, extra: [FrontmatterPair] = []) {
        self.path = path; self.id = id; self.title = title; self.tags = tags
        self.created = created; self.updated = updated; self.body = body
        self.extra = extra
    }
}
