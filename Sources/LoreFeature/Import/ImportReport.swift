import Foundation

/// Per-item outcome of `ImportApplier.apply`. One item can land in at most one
/// of `imported`/`skipped`, but can ALSO contribute to `failed` even when it
/// otherwise succeeded — an item whose note wrote fine but whose attachment
/// could not be copied still counts as imported, with the attachment failure
/// reported separately (see `ImportApplierTests.testOneFailedItemDoesNotAbortTheRun`).
public struct ImportReport: Sendable {
    public var imported: [URL] = []
    public var skipped: [(id: String, reason: String)] = []
    public var failed: [(id: String, reason: String)] = []

    public init(imported: [URL] = [],
                skipped: [(id: String, reason: String)] = [],
                failed: [(id: String, reason: String)] = []) {
        self.imported = imported
        self.skipped = skipped
        self.failed = failed
    }
}
