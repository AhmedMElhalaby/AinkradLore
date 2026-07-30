import Foundation

// The store-side half of the editor's link affordances: which text to WRITE for
// a link so that reading it back finds the same document, and whether a path
// derived from link text really lands inside the vault.
//
// Both are here rather than in the views because both need the resolver or the
// vault root, and neither is a rendering concern. Extracted from `LoreStore.swift`
// to keep that file under the project's 500-line ceiling.
extension LoreStore {
    /// The wikilink target to write for `row`, guaranteed — where the vault
    /// makes it possible at all — to resolve back to `row` and not to some
    /// other document that happens to share its title.
    ///
    /// Lives here rather than in the view because the guarantee needs the
    /// resolver and the vault root; the decision itself is the pure
    /// `LinkCompletionContext.insertableTarget`.
    public func linkTarget(for row: IndexRow) -> String {
        LinkCompletionContext.insertableTarget(
            for: row,
            relativePath: Self.vaultRelativePath(of: row.path, under: vaultRoot),
            resolves: { [weak self] in self?.resolveLink($0) })
    }

    /// Whether `url` really sits inside `root` once symlinks are resolved.
    ///
    /// Resolves the deepest ancestor that actually exists, so it is meaningful
    /// for a directory that has not been created yet: the symlink that could
    /// redirect the write is by definition already on disk.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        var existing = url.standardizedFileURL
        var trailing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              existing.pathComponents.count > 1 {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in trailing { resolved.appendPathComponent(part) }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = resolved.standardizedFileURL.path
        // The `/` matters: without it `/vault-backup` counts as inside `/vault`.
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath
                                                                         : rootPath + "/")
    }

    /// `Projects/Design` for `<vault>/Projects/Design.md`. Empty when the
    /// document is not under the vault root — in which case no path target
    /// could name it anyway.
    static func vaultRelativePath(of url: URL, under root: URL?) -> String {
        guard let root else { return "" }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.deletingPathExtension().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return "" }
        return String(path.dropFirst(prefix.count))
    }

}
