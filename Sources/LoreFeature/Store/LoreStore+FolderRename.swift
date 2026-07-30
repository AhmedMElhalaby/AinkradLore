import Foundation

/// The change set for renaming a FOLDER, computed before anything is written.
///
/// ## Why this is one folder move and not N document moves
///
/// The first cut of folder rename was N independent single-document moves over
/// the indexed rows beneath the folder. Three things were wrong with that, and
/// all three are data problems rather than tidiness problems:
///
///  - The old folder survived, empty, because nothing ever removed it.
///  - Every file the INDEX does not claim — images, PDFs, `.excalidraw`,
///    anything an engine cannot open and the scan skipped — was left behind in
///    the old folder. A note that moved and referenced an attachment that did
///    not is an orphaned attachment: the rename broke the very reference it
///    exists to preserve.
///  - A folder containing zero indexed documents produced zero plans, and a
///    report of nothing is indistinguishable from a report of success. The
///    folder was never renamed and nothing said so.
///
/// So the directory itself is moved, once, and everything inside travels with
/// it whether the index knows about it or not. Link rewriting is then applied
/// to the documents that moved, through the SAME
/// `rewriteInboundLinks`/`reloadRewritten` pass single-document rename uses —
/// there is no second write path, and therefore no second, weaker copy of the
/// plan-time baselines, the skip-if-changed-on-disk guard, the
/// exclude-files-with-unsaved-edits rule, the identity-tracked sessions, or the
/// three-state `EditOutcome`.
public struct FolderRenamePlan: Sendable {
    public let source: URL
    public let destination: URL
    /// Every INDEXED document beneath `source`, paired with the path it will
    /// have once the folder has moved. Unindexed files are not listed because
    /// nothing needs to be planned for them — they move with the directory —
    /// but they do move.
    public let documentMoves: [(from: URL, to: URL)]
    public let edits: [LinkEdit]
    public let unrewritable: [UnrewritableLink]
    public let baselines: [String: Date]
    /// See `RenamePlan.refusal`. `apply` writes and creates nothing.
    public let refusal: String?

    public init(source: URL, destination: URL,
                documentMoves: [(from: URL, to: URL)] = [],
                edits: [LinkEdit] = [], unrewritable: [UnrewritableLink] = [],
                baselines: [String: Date] = [:], refusal: String? = nil) {
        self.source = source; self.destination = destination
        self.documentMoves = documentMoves; self.edits = edits
        self.unrewritable = unrewritable; self.baselines = baselines
        self.refusal = refusal
    }

    /// First-seen order, deduplicated — the file list the confirmation UI shows.
    public var affectedFiles: [URL] {
        var seen = Set<String>()
        return edits.compactMap { seen.insert($0.file.path).inserted ? $0.file : nil }
    }

    /// True when the folder holds no indexed documents. NOT the same as "no
    /// work to do": the folder still gets renamed, and `apply` still reports
    /// `movedTo`.
    public var hasNoIndexedDocuments: Bool { documentMoves.isEmpty }
}

extension LoreStore {

    /// Computes the change set for renaming `folder` to `newName`. Nothing is
    /// written.
    public func plan(renameFolder folder: URL, to newName: String) -> FolderRenamePlan {
        let source = VaultIndexCoordinator.canonical(folder)
        let parent = source.deletingLastPathComponent()
        if let refusal = nameRejection(newName, in: parent) {
            return FolderRenamePlan(source: source, destination: source, refusal: refusal)
        }
        let destination = Self.canonicalizingDestination(
            parent.appendingPathComponent(newName))

        let prefix = source.path + "/"
        let moves: [(from: URL, to: URL)] = rows
            .filter { $0.path.path.hasPrefix(prefix) }
            .map { row in
                (from: row.path,
                 to: destination.appendingPathComponent(
                        String(row.path.path.dropFirst(prefix.count))))
            }

        // One rewrite plan per moving document, merged into one edit list. A
        // link from a document inside the folder to another document inside it
        // is therefore planned against the final location of BOTH: the edit's
        // `file` is the linking document's pre-move path (correct, because
        // links are rewritten before the directory moves) while the target is
        // its post-move path.
        let root = canonicalVaultRoot(fallback: parent)
        var edits: [LinkEdit] = []
        var unrewritable: [UnrewritableLink] = []
        for move in moves {
            let sub = LinkRewriter.plan(renaming: move.from, to: move.to,
                                        inboundLinks: coordinator.inboundLinks(to: move.from),
                                        vaultRoot: root)
            edits += sub.edits
            unrewritable += sub.unrewritable
        }
        var seen = Set<String>()
        let files = edits.compactMap { seen.insert($0.file.path).inserted ? $0.file : nil }
        return FolderRenamePlan(source: source, destination: destination,
                                documentMoves: moves, edits: edits,
                                unrewritable: unrewritable,
                                baselines: Self.baselines(for: files))
    }

    /// Applies `plan`: rewrites every inbound link, then moves the directory.
    /// Never throws — partial success is expected and reported.
    ///
    /// ORDERING, for the same reason as single-document rename: links FIRST. A
    /// crash between the two leaves links pointing at a folder that still
    /// exists (still resolvable, and re-running fixes it) rather than at one
    /// that is gone.
    @discardableResult
    public func apply(_ plan: FolderRenamePlan) -> RenameReport {
        if let refusal = plan.refusal {
            return RenameReport(rewritten: [], skipped: [],
                                failed: [(plan.source, refusal)], movedTo: nil)
        }
        var failed = Self.unrewritableFailures(plan.unrewritable)

        // Every refusal runs BEFORE the first write and before the first
        // directory is created — nothing here leaves residue behind for an
        // operation that then declines to happen.
        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: plan.source.path,
                                            isDirectory: &sourceIsDirectory),
              sourceIsDirectory.boolValue else {
            failed.append((plan.source, "The folder no longer exists."))
            return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
        }
        // A case-only rename (`Projects` → `projects`) on a case-INSENSITIVE
        // volume — the macOS default — resolves to the same directory, so the
        // "already exists" guard below would refuse a perfectly ordinary
        // rename. `rename(2)`, which `moveItem` uses, performs a case-only
        // rename in place, so this is safe to let through. Compared on the
        // canonical paths so it cannot be spoofed by a differently-spelled
        // ancestor.
        let isCaseOnlyRename =
            plan.destination.path.caseInsensitiveCompare(plan.source.path) == .orderedSame
        if !isCaseOnlyRename,
           FileManager.default.fileExists(atPath: plan.destination.path) {
            failed.append((plan.destination, "A folder with that name already exists."))
            return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
        }
        let parent = plan.destination.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path,
                                            isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            failed.append((parent, "The destination folder does not exist."))
            return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            failed.append((parent, "The destination folder is not writable."))
            return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
        }

        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)

        // Resolved BEFORE the move: `canonical` is `realpath(3)`, which fails
        // on a path that no longer exists. Matched by PREFIX rather than
        // against `plan.documentMoves`, so a tab open on a file the index does
        // not claim (an unclaimed type, a file created since the last rescan)
        // still follows the folder instead of being left pointing into a
        // directory that is gone.
        let prefix = plan.source.path + "/"
        var following: [(session: DocumentSession, from: URL, to: URL)] = []
        for session in tabs {
            let path = VaultIndexCoordinator.canonical(session.url).path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            following.append((session, URL(fileURLWithPath: path),
                              plan.destination.appendingPathComponent(relative)))
        }

        // Links FIRST, then the directory move. `movingPaths` covers every file
        // that is about to relocate — indexed documents AND any open tab under
        // the folder — so each such session is flushed and its debounced
        // autosave disarmed before the ground moves under it.
        var movingPaths = Set(plan.documentMoves.map {
            VaultIndexCoordinator.canonical($0.from).path
        })
        movingPaths.formUnion(following.map { $0.from.path })
        let pass = rewriteInboundLinks(edits: plan.edits, baselines: plan.baselines,
                                       movingPaths: movingPaths)
        failed += pass.failed

        var moved: URL?
        do {
            try FileManager.default.moveItem(at: plan.source, to: plan.destination)
            moved = plan.destination
            for entry in following {
                entry.session.adoptRenamed(entry.to)
                transferOpenMTime(from: entry.from, to: entry.to)
            }
        } catch {
            failed.append((plan.source, error.localizedDescription))
        }

        // Reloaded only if the session is not still dirty — see
        // `reloadRewritten`. Runs after `adoptRenamed`, so a session under the
        // folder reloads from its NEW location.
        reloadRewritten(pass)

        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)
        try? rebuild()

        // A rewritten file that lived inside the folder must be reported at its
        // new path: the old one no longer exists by the time the UI renders.
        let reported = pass.rewritten.map { Self.relocating($0, from: prefix, to: moved) }
        return RenameReport(rewritten: reported.sorted { $0.path < $1.path },
                            skipped: pass.skipped.map { Self.relocating($0, from: prefix, to: moved) }
                                .sorted { $0.path < $1.path },
                            unchanged: pass.unchanged.map { Self.relocating($0, from: prefix, to: moved) }
                                .sorted { $0.path < $1.path },
                            failed: failed, movedTo: moved)
    }

    private static func relocating(_ url: URL, from prefix: String, to destination: URL?) -> URL {
        guard let destination, url.path.hasPrefix(prefix) else { return url }
        return destination.appendingPathComponent(String(url.path.dropFirst(prefix.count)))
    }
}
