import Foundation

/// Writes an `ImportPlan` to disk and reports what happened, item by item.
///
/// `@MainActor`, not because the applier needs UI access, but because it
/// reuses `LoreStore.nonCollidingURL` — the SAME on-disk collision scan
/// `writeAttachment` uses — which is `@MainActor`-isolated as a consequence of
/// `LoreStore` being `@MainActor`. The applier deliberately does NOT hold a
/// `LoreStore` instance (that method is bound to a live vault; this must run
/// against a plain directory in tests), so it calls the static helper
/// directly instead of duplicating its dedup logic.
///
/// THE INVARIANT: `apply` writes FILES ONLY, never index rows. The index is
/// derived by the watcher and `VaultIndexCoordinator` from what lands on
/// disk — writing index rows here would let the index and the files
/// disagree, which is the structural guarantee M3 established. Do not import
/// or call any index/database type from this file.
@MainActor
public struct ImportApplier {
    let vaultRoot: URL

    public init(vaultRoot: URL) {
        self.vaultRoot = vaultRoot
    }

    /// Applies every non-`.alreadyImported` item in `plan`. One item's
    /// failure never aborts the run — the whole point of importing N items
    /// is that a single locked note or missing attachment must not cost the
    /// user the other N-1 that were fine.
    ///
    /// ATOMICITY, HONESTLY: a single item is not atomic. Attachments are
    /// copied before the note is written (so a written note never points at
    /// a missing attachment), but if the note write itself then fails, those
    /// already-copied attachments are left behind, orphaned, with nothing
    /// referencing them. This is a deliberate trade-off, not an oversight:
    /// the alternative (deleting them back out on failure) adds a second
    /// failure mode of its own on a path that already failed once, and a
    /// stray attachment file is recoverable by hand while a half-imported
    /// note silently missing its media is not. See task-11-report.md.
    public func apply(_ plan: ImportPlan) async -> ImportReport {
        var report = ImportReport()

        for planned in plan.items {
            if planned.disposition == .alreadyImported {
                report.skipped.append((planned.item.sourceID, "already imported"))
                continue
            }
            do {
                try apply(planned, into: &report)
            } catch {
                report.failed.append((planned.item.sourceID, error.localizedDescription))
            }
        }
        return report
    }

    private func apply(_ planned: PlannedItem, into report: inout ImportReport) throws {
        let directory = planned.targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The planner only resolves collisions WITHIN the selection being
        // imported (see `ImportPlanner`'s doc comment). It has no view of
        // what is already on disk — a note the user wrote themselves, or a
        // survivor of a previous partial import. Re-resolving against the
        // real directory here, with the SAME Finder-style " 2" scheme
        // `writeAttachment` uses, is what keeps this from ever overwriting
        // the user's own data.
        let noteURL = LoreStore.nonCollidingURL(
            in: directory, preferredName: planned.targetURL.lastPathComponent)

        // Attachments before the note: a written note must never point at an
        // attachment that does not exist yet.
        for attachment in planned.item.attachments {
            guard let source = attachment.sourceURL else {
                report.failed.append((attachment.sourceID, "no data available"))
                continue
            }
            do {
                let destination = LoreStore.nonCollidingURL(
                    in: directory, preferredName: LoreStore.sanitized(attachment.preferredName))
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                report.failed.append((attachment.sourceID, error.localizedDescription))
            }
        }

        let markdown: String
        switch planned.item.body {
        case .markdown(let text):
            markdown = text
        case .html(let html):
            let converted = HTMLToMarkdown.convert(html)
            markdown = converted.markdown
            // Keep the original beside the note: a lossy HTML->Markdown
            // conversion must stay recoverable without going back to the
            // source app. Unlike the brief's `try?`, a failure here THROWS —
            // a silently missing original defeats that guarantee, so it is
            // treated as a failure of the whole item rather than swallowed.
            let original = noteURL.deletingPathExtension().appendingPathExtension("original.html")
            try html.write(to: original, atomically: true, encoding: .utf8)
        }

        try Self.frontmatterBody(markdown, item: planned.item)
            .write(to: noteURL, atomically: true, encoding: .utf8)
        report.imported.append(noteURL)
    }

    /// Builds the note text via `Frontmatter.serialize`, not string
    /// interpolation: a title containing a colon, a leading `-`, or a
    /// newline would otherwise produce invalid YAML that `Frontmatter.parse`
    /// could then mis-read. `lore_import_id` is not one of `Frontmatter`'s
    /// modelled keys, so it is spliced into the header as an extra line —
    /// `Frontmatter.parse` reads any unmodelled key back untouched, and
    /// preserves it verbatim on every future save.
    static func frontmatterBody(_ markdown: String, item: ImportItem) -> String {
        let note = Note(path: URL(fileURLWithPath: "/dev/null"), id: UUID().uuidString,
                        title: item.title, tags: [], created: item.created,
                        updated: item.modified, body: markdown)
        let serialized = Frontmatter.serialize(note)
        return withImportID(item.sourceID, insertedInto: serialized)
    }

    /// Inserts `lore_import_id: <id>` as the last line of the frontmatter
    /// header, right before the closing `---` fence. `sourceID` is a value
    /// this codebase constructs itself (`"apple-notes:<id>"`,
    /// `"obsidian:<path>"`) rather than arbitrary user text, so it is
    /// written unquoted and verbatim — matching how every scanner and test
    /// in this milestone expects to find it.
    private static func withImportID(_ id: String, insertedInto serialized: String) -> String {
        var lines = serialized.components(separatedBy: "\n")
        guard let closeOffset = lines.dropFirst().firstIndex(of: "---") else { return serialized }
        lines.insert("lore_import_id: \(id)", at: closeOffset)
        return lines.joined(separator: "\n")
    }
}
