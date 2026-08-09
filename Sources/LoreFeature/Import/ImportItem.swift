import Foundation

public enum ImportBody: Sendable, Equatable {
    case html(String)
    case markdown(String)
}

public struct ImportAttachment: Sendable, Equatable {
    public let sourceID: String
    public let preferredName: String
    /// Where the bytes live right now. Nil when the source could not produce them,
    /// in which case the item carries a `.attachmentUnavailable` warning instead.
    public let sourceURL: URL?
    public init(sourceID: String, preferredName: String, sourceURL: URL?) {
        self.sourceID = sourceID
        self.preferredName = preferredName
        self.sourceURL = sourceURL
    }
}

public struct FidelityWarning: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case unsupportedElement      // converter met markup it does not model
        case attachmentUnavailable   // referenced media could not be read
        case lockedNote              // encrypted; skipped by design
        case pluginSyntax            // Dataview/callout copied through verbatim
    }
    public let kind: Kind
    public let detail: String
    public init(kind: Kind, detail: String) { self.kind = kind; self.detail = detail }
}

public struct ImportItem: Sendable, Equatable {
    public let sourceID: String
    public let title: String
    public let body: ImportBody
    public let attachments: [ImportAttachment]
    public let folderPath: [String]
    public let created: Date
    public let modified: Date
    public let fidelity: [FidelityWarning]

    public init(sourceID: String, title: String, body: ImportBody,
                attachments: [ImportAttachment], folderPath: [String],
                created: Date, modified: Date, fidelity: [FidelityWarning]) {
        self.sourceID = sourceID
        self.title = title
        self.body = body
        self.attachments = attachments
        self.folderPath = folderPath
        self.created = created
        self.modified = modified
        self.fidelity = fidelity
    }
}
