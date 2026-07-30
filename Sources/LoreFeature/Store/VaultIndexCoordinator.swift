import Foundation
import Observation

/// Owns the vault's derived state: the SQLite index, the folder watcher, and
/// the rescan lifecycle. Extracted from `LoreStore` unchanged — every comment
/// below records a real bug the code around it fixes.
@MainActor
@Observable
public final class VaultIndexCoordinator {
    public private(set) var rows: [IndexRow] = []
    public private(set) var vaultRoot: URL?

    private let indexPath: URL
    private var index: LoreIndex?
    private var watcher: FolderWatcher?
    /// While `Date() < suppressWatcherUntil`, `FolderWatcher` callbacks are
    /// ignored — see `save(_:overwritingExternalChanges:)`.
    private var suppressWatcherUntil: Date = .distantPast
    /// A background rescan is in flight.
    private var isRebuilding = false
    /// A vault change arrived while a rescan was running — run once more after.
    private var rebuildRequestedAgain = false

    /// How long after our own write a watcher event is treated as the echo of
    /// that write. Generous enough to cover FSEvents' coalescing latency,
    /// short enough that a genuine external edit arriving right after a save
    /// is still picked up on the next event.
    static let selfWriteSuppressionWindow: TimeInterval = 1.0

    public init(indexPath: URL) {
        self.indexPath = indexPath
    }

    public func activate(root: URL) throws {
        // CANONICAL ON WRITE. `vaultRoot` is stored canonically and is never the
        // caller's spelling: it seeds `scanVault`'s enumerator (so every indexed
        // path derives from it) and it is the prefix `LinkRewriter` strips to
        // compute vault-relative link targets. Stored raw, a vault under `/tmp`
        // or `/var` — which is every test vault, and some real ones — put a
        // second spelling of every path into circulation. See the invariant on
        // `LoreIndex.canonical(_:)`.
        let root = Self.canonical(root)
        vaultRoot = root
        index = try LoreIndex(path: indexPath)
        // Paint immediately from whatever the index already holds — a reopen
        // then shows the vault instantly — and refresh from disk in the
        // background. Crucially NOT a synchronous `rebuild()`: `activate` runs
        // from `LoreStore.init`, which the host calls from `LoreApp.store(for:)`
        // inside `makeRootView` — i.e. inside a SwiftUI `body` evaluation. A
        // whole-vault scan there froze the UI on first open, for as long as the
        // user's vault was large.
        rows = (try? index?.all()) ?? []
        startBackgroundRebuild()
        watcher = FolderWatcher(url: root) { [weak self] in self?.handleVaultChange() }
    }

    /// Releases everything this store owns: the vault watcher, any in-flight
    /// rescan, and the SQLite index (and with it its file descriptor).
    ///
    /// Called from `LoreApp.teardown` when the host closes this instance. Until
    /// generation 8 there was no way for the host to say that, so all of this
    /// leaked for the lifetime of the process every time Lore was removed.
    public func shutdown() {
        watcher = nil
        rebuildRequestedAgain = false
        index = nil
        rows = []
        vaultRoot = nil
    }

    /// Watcher entry point. Drops the echo of our own writes so a save doesn't
    /// trigger a full-vault rescan of a vault we just updated in place.
    func handleVaultChange() {
        guard Date() >= suppressWatcherUntil else { return }
        startBackgroundRebuild()
    }

    /// Ignore watcher callbacks for `interval` — used across our own writes so
    /// a save does not trigger a full-vault rescan of a vault we just updated
    /// in place. See the original rationale on `save`.
    func suppressWatcher(for interval: TimeInterval) {
        suppressWatcherUntil = Date().addingTimeInterval(interval)
    }

    /// Test seam: wait until no background rescan is in flight.
    ///
    /// `activate` kicks one off, and `async` tests suspend often enough for its
    /// `replaceAll` to land in the middle of one — wiping notes the test had
    /// already created. Synchronous `XCTest` cases never yielded, so this only
    /// became necessary with the `async` swift-testing suites.
    func settleForTesting() async {
        while isRebuilding { await Task.yield() }
    }

    /// Kicks off an off-actor rescan, coalescing with one already in flight.
    ///
    /// FSEvents delivers bursts (a `git checkout` in the vault is hundreds of
    /// events), and each used to start its own full synchronous rescan on the
    /// main actor. Now at most one runs at a time, off the main actor, and a
    /// burst arriving during one schedules exactly one follow-up.
    func startBackgroundRebuild() {
        guard !isRebuilding else { rebuildRequestedAgain = true; return }
        isRebuilding = true
        Task { [weak self] in
            await self?.performBackgroundRebuild()
        }
    }

    private func performBackgroundRebuild() async {
        defer {
            isRebuilding = false
            if rebuildRequestedAgain {
                rebuildRequestedAgain = false
                startBackgroundRebuild()
            }
        }
        guard let root = vaultRoot, let index else { return }
        // Walk, read and parse every note off the main actor, then apply the
        // whole result in one transaction. `LoreIndex` is Sendable (it holds
        // only a GRDB `DatabaseQueue`, which serializes its own access).
        let refreshed: [IndexRow]? = await Task.detached(priority: .utility) { () -> [IndexRow]? in
            let notes = Self.scanVault(at: root)
            do {
                try index.replaceAll(with: notes)
                return try index.all()
            } catch {
                return nil
            }
        }.value
        if let refreshed { rows = refreshed }
    }

    /// Pure, off-actor: every engine-openable file under `root`, loaded and
    /// reduced to its index payload. No index access.
    ///
    /// Files no engine claims are indexed too, but METADATA ONLY: type
    /// `EngineRegistry.unclaimedType`, empty plaintext, the filename (with its
    /// extension — there is no engine to derive anything better) as the title.
    ///
    /// They used to be skipped entirely, which made the sidebar lie: a vault of
    /// `.pdf`/`.xlsx` showed as empty, and `FallbackViewer`'s "can't open this
    /// yet" branch was unreachable because nothing could ever be clicked to
    /// reach it. The spec's failure-modes table requires the opposite. Empty
    /// plaintext is the point: an unclaimed row must never match a full-text
    /// search for content nobody parsed.
    nonisolated static func scanVault(at root: URL) -> [IndexEntry] {
        // CANONICAL ON WRITE, part 1: the enumerator builds every URL it yields
        // by appending to the URL it was given, so canonicalizing the root ONCE
        // here makes every `IndexEntry.url` below canonical — without a
        // `realpath(3)` per file. `activate` already stores a canonical
        // `vaultRoot`, so in production this is a no-op; it is here because
        // `scanVault` is also called directly (tests, `rebuild()`) and the
        // invariant must not depend on which door the caller came through.
        let root = Self.canonical(root)
        var entries: [IndexEntry] = []
        // Only components BELOW the root are ours to judge. Testing the
        // absolute path would make a vault under any dot-prefixed ancestor —
        // `~/.local/share/notes`, a `.worktrees/` checkout, a sandbox
        // container — index zero files, silently, showing an empty vault with
        // no error to explain it.
        let rootDepth = root.standardizedFileURL.pathComponents.count
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .isDirectoryKey, .isPackageKey,
            ],
            options: [.skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            // Skip package internals and tool directories: `.obsidian`,
            // `.git`, `.trash`, and (later) `.lore` package contents are not
            // documents in their own right.
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            if relative.contains(where: { $0.hasPrefix(".") }) { continue }
            // Directories are not documents. They were filtered out for free
            // while unclaimed files were skipped; now that those are indexed,
            // every folder would otherwise become a row. A PACKAGE is also a
            // directory, but `.skipsPackageDescendants` above means its
            // internals are never walked — so unlike a plain directory, the
            // package itself must be indexed as a single unclaimed row, or it
            // (and everything a user would recognize as "the document")
            // disappears from the vault entirely.
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey])
            if values?.isDirectory == true && values?.isPackage != true { continue }
            // File mtime is DELIBERATELY authoritative for `updated`, and
            // supersedes markdown's frontmatter `updated:` value, which the
            // pre-M0 scan used. Two reasons: it is uniform across document
            // types (plaintext has no frontmatter to read), and the
            // frontmatter field is day-granularity, so a whole day's notes
            // tie and `ORDER BY updated DESC` sorts them arbitrarily. This
            // changes sidebar ordering for vaults where the two disagree.
            let updated = values?.contentModificationDate ?? Date()

            // An engine that claims the file but fails to LOAD it is left out,
            // as before: that is a real error, not an unclaimed type, and this
            // scan has nowhere to report it.
            guard let engineType = EngineRegistry.engine(for: url) else {
                entries.append(IndexEntry(
                    url: url, type: EngineRegistry.unclaimedType,
                    payload: IndexPayload(title: url.lastPathComponent, plaintext: ""),
                    updated: updated))
                continue
            }
            guard let engine = try? engineType.load(url) else { continue }
            var payload = engine.indexPayload
            payload.plaintext = Self.capped(payload.plaintext)
            entries.append(IndexEntry(url: url, type: engineType.identifier,
                                      payload: payload, updated: updated))
        }
        // Resolution is a second pass because a link can point at any document
        // in the vault, including one the enumerator has not reached yet.
        //
        // CANONICAL ON WRITE, part 2: `LinkResolver` returns one of the URLs it
        // was given, and every `entry.url` here is canonical (part 1) — so every
        // `ResolvedLink.targetPath`, and therefore every `links.target_path`
        // row, is canonical too. That is what makes `backlinks`,
        // `inboundLinks` and `inboundLinkCount` truthful.
        let resolver = LinkResolver(documents: entries.map {
            (url: $0.url, title: $0.payload.title, aliases: $0.payload.aliases)
        })
        return entries.map { entry in
            IndexEntry(url: entry.url, type: entry.type, payload: entry.payload,
                       updated: entry.updated,
                       resolvedLinks: entry.payload.links.map {
                           ResolvedLink(rawTarget: $0.rawTarget,
                                        targetPath: resolver.resolve($0.rawTarget),
                                        isEmbed: $0.isEmbed)
                       })
        }
    }

    /// Upper bound on the indexed text of a single document.
    ///
    /// `scanVault` holds every loaded payload resident until `replaceAll`
    /// applies them in one transaction, so without a cap total rescan memory
    /// is the size of the vault's indexable content. That was tolerable when
    /// only `.md` was scanned; `PlainTextEngine` claims `log`, `csv` and
    /// `json`, where single files run to hundreds of megabytes. Searching the
    /// first megabyte of a giant log is the right trade — holding the whole
    /// corpus in RAM is not. Truncation affects the INDEX ONLY; nothing here
    /// touches what is written back to disk.
    nonisolated static let maxIndexedPlaintextBytes = 1_048_576

    /// Truncates to at most `maxIndexedPlaintextBytes` UTF-8 bytes, cutting on
    /// a scalar boundary so the result is never a mangled half-character.
    nonisolated static func capped(_ text: String) -> String {
        guard text.utf8.count > maxIndexedPlaintextBytes else { return text }
        var bytes = Array(text.utf8.prefix(maxIndexedPlaintextBytes))
        // Walk back to the last lead byte (anything that is not a 10xxxxxx
        // continuation). If the sequence it starts would run past the cut, the
        // scalar is incomplete — drop it whole.
        var i = bytes.count - 1
        while i >= 0, bytes[i] & 0xC0 == 0x80 { i -= 1 }
        if i >= 0 {
            let lead = bytes[i]
            let width = lead < 0x80 ? 1 : (lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4))
            if i + width > bytes.count { bytes.removeSubrange(i...) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Synchronous rescan. Kept for tests and for callers that must observe the
    /// result immediately; production paths use `startBackgroundRebuild`.
    public func rebuild() throws {
        guard let root = vaultRoot, let index else { return }
        try index.replaceAll(with: Self.scanVault(at: root))
        rows = try index.all()
    }

    public func search(_ query: String) -> [IndexRow] {
        (try? index?.search(query)) ?? []
    }

    /// `FileManager`'s enumerator (in `scanVault`) hands back paths resolved
    /// via `realpath(3)` — on macOS `/tmp` and `/var` are themselves symlinks
    /// into `/private`, and `URL.resolvingSymlinksInPath()` deliberately
    /// leaves those three roots alone (Apple's documented exception). Without
    /// matching that resolution here, a caller-constructed URL under either
    /// path (any vault under `/tmp`, and every test vault) would never match
    /// a stored row and silently return no backlinks.
    ///
    /// Internal (not private) since Task 7: `LoreStore`'s rename planner must
    /// source the vault root, the rename source AND the destination through
    /// THIS function. `LinkRewriter` computes vault-relative targets by
    /// comparing path COMPONENTS, so mixing a canonical root
    /// (`/private/tmp/v`) with a raw destination (`/tmp/v/x.md`) fails the
    /// prefix match and drops every edit silently — a clean-looking rename
    /// that breaks every inbound link.
    ///
    /// `realpath(3)` fails on a path that does not exist yet, in which case it
    /// returns `url` untouched — so a caller canonicalizing a rename
    /// DESTINATION must canonicalize its existing parent directory and
    /// re-append the last component (see `LoreStore.canonicalizingDestination`).
    /// `nonisolated` because the invariant is enforced off the main actor too:
    /// `scanVault` runs in a detached task, and `LoreIndex` (a `Sendable` type
    /// used from that task) routes every stored path through here.
    nonisolated static func canonical(_ url: URL) -> URL {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    func backlinkRows(to url: URL) -> [IndexRow] {
        (try? index?.backlinks(to: Self.canonical(url))) ?? []
    }

    /// Every (file, rawTarget) pair pointing at `url` — the raw material for a
    /// rename's change set. Canonicalized like every other index lookup.
    ///
    /// The RESULT is canonicalized too, not just the lookup argument.
    /// `links.source_path` is stored with whatever spelling the row carried when
    /// it was written, and `indexDocument` writes the caller's URL verbatim — so
    /// a document indexed outside a full rescan can be stored `/var/...` while
    /// everything downstream of a rename compares against `/private/var/...`.
    /// Every consumer of this function keys dictionaries and sets by these
    /// paths and matches them against canonical session URLs; handing back two
    /// spellings makes those lookups miss, which in this codebase has meant an
    /// edit silently dropped or a dirty tab's file written anyway. One spelling
    /// out of here is what stops that at the source.
    func inboundLinks(to url: URL) -> [(sourceFile: URL, rawTarget: String)] {
        let links = (try? index?.inboundLinks(to: Self.canonical(url))) ?? []
        return links.map { (sourceFile: Self.canonical($0.sourceFile), rawTarget: $0.rawTarget) }
    }
    func unresolvedLinks(from url: URL) -> [String] {
        (try? index?.unresolvedLinks(from: Self.canonical(url))) ?? []
    }
    /// A resolver over the CURRENT index rows, for link clicks and completion.
    func currentResolver() -> LinkResolver {
        LinkResolver(documents: rows.map {
            (url: $0.path, title: $0.title, aliases: $0.aliases)
        })
    }

    /// Index one document after a save, without a whole-vault rescan.
    ///
    /// Resolves this document's own outbound links immediately, against the
    /// current `rows` plus the document being indexed — so a note saved with
    /// a new link shows that link's backlink without waiting for a full
    /// rescan. Built from `rows` rather than a fresh scan, so it does not pay
    /// for a whole-vault walk on every save.
    func indexDocument(_ engine: any DocumentEngine, at url: URL) throws {
        guard let index else { throw LoreError.noVault }
        // CANONICAL ON WRITE, part 3: this was THE hole. `indexDocument` upserted
        // the caller's URL verbatim, so a save routed through a `/tmp`-spelled
        // URL wrote a non-canonical `documents.path` AND non-canonical
        // `links.target_path` rows pointing at it — after which every read
        // (which canonicalizes) matched nothing for that document, silently.
        // Canonicalizing here means the `LinkResolver` below, the upserted row
        // and the resolved link targets are all one spelling.
        let url = Self.canonical(url)
        let type = type(of: engine).identifier
        let payload = engine.indexPayload
        // Exclude the STALE row for this same document (if it already exists in
        // `rows`): otherwise its old title/alias keys would stay resolvable
        // until the next full rescan, alongside the fresh keys appended below.
        //
        // Both sides are canonical: `rows` come from `LoreIndex`, which stores
        // only canonical paths, and `url` was canonicalized above. Compared raw
        // (as it was) the filter failed to exclude a row spelled differently
        // from the incoming URL, and the old title/alias stayed resolvable.
        var documents = rows.filter { $0.path != url }
            .map { (url: $0.path, title: $0.title, aliases: $0.aliases) }
        documents.append((url: url, title: payload.title, aliases: payload.aliases))
        let resolver = LinkResolver(documents: documents)
        let resolvedLinks = payload.links.map {
            ResolvedLink(rawTarget: $0.rawTarget,
                         targetPath: resolver.resolve($0.rawTarget),
                         isEmbed: $0.isEmbed)
        }
        try index.upsert(IndexEntry(url: url, type: type, payload: payload,
                                    updated: Date(), resolvedLinks: resolvedLinks))
        rows = try index.all()
    }

    func removeFromIndex(_ url: URL) throws {
        guard let index else { throw LoreError.noVault }
        try index.remove(path: url)
        rows = try index.all()
    }

    /// True once a vault is active — the store's `noVault` guard.
    var hasIndex: Bool { index != nil }
}
