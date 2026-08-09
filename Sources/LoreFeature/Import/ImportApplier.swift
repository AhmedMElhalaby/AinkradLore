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
    ///
    /// What IS rolled back on failure: the note's own placeholder and its
    /// `.original.html` sidecar placeholder, IF they were never filled with
    /// real content, plus the directory itself if this call created it and
    /// nothing at all ended up inside. Those are pure applier bookkeeping,
    /// not user data, so there is no honesty trade-off in removing them.
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
        let directoryPreexisted = FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Placeholders reserved up front, and which of them ended up with
        // real content. Anything left reserved-but-not-final when this item
        // fails is applier bookkeeping, not user data — see `rollback` below.
        var reserved: [URL] = []
        var finalized: Set<URL> = []

        func rollback() {
            for url in reserved where !finalized.contains(url) {
                try? FileManager.default.removeItem(at: url)
            }
            if !directoryPreexisted,
               let remaining = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
               remaining.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        do {
            // Attachment-only items (every non-`.md` file in an Obsidian
            // vault: images, PDFs, etc. — see `ObsidianSource.scanSync`)
            // arrive with an empty body and themselves as the sole
            // attachment. Writing a note file for one of those produces a
            // junk `pic.png.md` alongside the real `pic.png` for every
            // binary file in the vault. "Empty body" is checked precisely:
            // whitespace-only markdown counts (a note that is truly nothing
            // but blank lines earns the same treatment), and `.html("")`
            // counts too since it collapses to the same empty markdown via
            // `HTMLToMarkdown.convert`. An empty body with NO attachments is
            // NOT attachment-only — that's a genuinely empty note the user
            // wrote (or a corrupt/unreadable one flagged via fidelity
            // warnings), and it still gets written so the fidelity warning
            // has something to attach to.
            let isEmptyBody: Bool
            switch planned.item.body {
            case .markdown(let text):
                isEmptyBody = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .html(let html):
                isEmptyBody = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let isAttachmentOnly = isEmptyBody && !planned.item.attachments.isEmpty

            if isAttachmentOnly {
                var landed: URL?
                for attachment in planned.item.attachments {
                    guard let source = attachment.sourceURL else {
                        report.failed.append((attachment.sourceID, "no data available"))
                        continue
                    }
                    do {
                        let destination = LoreStore.nonCollidingURL(
                            in: directory, preferredName: LoreStore.sanitized(attachment.preferredName))
                        try FileManager.default.copyItem(at: source, to: destination)
                        report.imported.append(destination)
                        if landed == nil { landed = destination }
                    } catch {
                        report.failed.append((attachment.sourceID, error.localizedDescription))
                    }
                }
                // A binary cannot carry `lore_import_id` — a PNG has nowhere to
                // put a YAML header — so the ONLY record that this item was
                // imported is the ledger. Without it a re-scan re-copies every
                // image as `pic 2.png`, `pic 3.png`, … unbounded. Recorded
                // AFTER the copies and only when at least one landed, so a
                // wholly failed item is never marked as imported; keyed to the
                // first landed file so deleting it un-marks the item (see
                // `ImportLedger`).
                if let landed {
                    do {
                        try ImportLedger.record(id: planned.item.sourceID,
                                                landedAt: landed, vaultRoot: vaultRoot)
                    } catch {
                        // The bytes DID land, so this is not an item failure —
                        // but staying silent would mean a re-import duplicates
                        // this file with nothing to warn the user. It is
                        // reported alongside the successful import, which is
                        // exactly the truth of what happened.
                        report.failed.append((
                            planned.item.sourceID,
                            "imported, but its import id could not be recorded "
                                + "(re-importing may duplicate it): \(error.localizedDescription)"))
                    }
                }
                return
            }

            // The planner only resolves collisions WITHIN the selection
            // being imported (see `ImportPlanner`'s doc comment). It has no
            // view of what is already on disk — a note the user wrote
            // themselves, or the survivor of a previous partial import.
            // Re-resolving against the real directory here, with the SAME
            // Finder-style " 2" scheme `writeAttachment` uses, is what keeps
            // this from ever overwriting the user's own data.
            let noteURL = LoreStore.nonCollidingURL(
                in: directory, preferredName: planned.targetURL.lastPathComponent)
            try Self.reserve(noteURL)
            reserved.append(noteURL)

            // The `.original.html` sidecar goes through the SAME on-disk
            // collision check as the note — a user who already owns
            // `Bold.original.html` (their own file, or a leftover from a
            // previous partial import) must not have it silently truncated.
            //
            // Both the note's and the sidecar's names are reserved with an
            // empty placeholder BEFORE the attachment loop below runs, not
            // just resolved. Resolving without reserving would leave a
            // window where an attachment whose sanitized name happens to
            // collide with either (a note called `Plan.md` importing an
            // attachment literally named `Plan.md`) sees an empty directory,
            // gets copied to that exact path, and is then silently
            // overwritten — data loss with no `failed` entry — when the
            // note/sidecar write happens for real.
            var sidecarURL: URL?
            if case .html = planned.item.body {
                let sidecarName = noteURL.deletingPathExtension()
                    .appendingPathExtension("original.html").lastPathComponent
                let resolved = LoreStore.nonCollidingURL(in: directory, preferredName: sidecarName)
                try Self.reserve(resolved)
                reserved.append(resolved)
                sidecarURL = resolved
            }

            // Attachments before the note: a written note must never point
            // at an attachment that does not exist yet.
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
                // source app. Unlike the brief's `try?`, a failure here
                // THROWS — a silently missing original defeats that
                // guarantee, so it is treated as a failure of the whole item
                // rather than swallowed.
                guard let sidecarURL else {
                    preconditionFailure("sidecarURL is reserved for every .html item above")
                }
                try html.write(to: sidecarURL, atomically: true, encoding: .utf8)
                finalized.insert(sidecarURL)
            }

            try Self.frontmatterBody(markdown, item: planned.item)
                .write(to: noteURL, atomically: true, encoding: .utf8)
            finalized.insert(noteURL)
            report.imported.append(noteURL)
        } catch {
            rollback()
            throw error
        }
    }

    /// Creates an empty placeholder at `url` so a later `nonCollidingURL`
    /// scan sees the name as taken. Throws on failure (e.g. an unwritable
    /// directory) rather than silently proceeding as if the name were free.
    private static func reserve(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw ReservationFailed(path: url.path)
        }
    }

    private struct ReservationFailed: Error, LocalizedError {
        let path: String
        var errorDescription: String? { "could not reserve \(path)" }
    }

    /// Builds the note text by hand, not via `Frontmatter.serialize`'s
    /// no-raw-frontmatter path: that path (`serializeFromModel`) formats
    /// `created`/`updated` as `yyyy-MM-dd`, silently dropping time-of-day for
    /// every note in what is usually a one-shot migration of the user's
    /// whole library. `ISO8601DateFormatter` — the brief's original choice —
    /// keeps it.
    ///
    /// Every value that is not a fixed literal goes through
    /// `Frontmatter.yamlScalar`, INCLUDING `lore_import_id`. That key is not
    /// one of `Frontmatter`'s modelled keys, but `sourceID` is not
    /// codebase-controlled either — `ObsidianSource` builds it from a user
    /// filesystem path (`"obsidian:\(relativePath)"`), and a path may
    /// legally contain a newline or a `#` on disk. Unescaped, a newline
    /// injects a bogus top-level YAML line and truncates the ID (so
    /// `existingImportIDs` never matches it again and a re-run duplicates
    /// the note — the exact failure idempotency exists to prevent), and a
    /// `#` is read back fine by this codebase's own lenient scanner but
    /// comment-truncated by any real YAML reader, including Obsidian's own
    /// properties pane. `yamlScalar` is what already solves this for
    /// `title`; there is no reason `lore_import_id` should be exempt.
    ///
    /// `nonisolated`: this is a pure string function, and its main-actor
    /// isolation was only ever INHERITED from `ImportApplier` (which is
    /// `@MainActor` for `LoreStore.nonCollidingURL`'s sake, not this). Same
    /// call as `LoreStore.sanitized` — an incidental isolation that stops
    /// callers off the main actor for no reason of its own.
    nonisolated static func frontmatterBody(_ markdown: String, item: ImportItem) -> String {
        let iso = ISO8601DateFormatter()
        let lines = [
            "id: \(Frontmatter.yamlScalar(UUID().uuidString))",
            "title: \(Frontmatter.yamlScalar(item.title))",
            "lore_import_id: \(Frontmatter.yamlScalar(item.sourceID))",
            "created: \(iso.string(from: item.created))",
            "updated: \(iso.string(from: item.modified))",
        ]
        return "---\n" + lines.joined(separator: "\n") + "\n---\n\n" + markdown
    }
}
