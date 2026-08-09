import Foundation

/// Turns a scanned selection of `ImportItem`s into an `ImportPlan` — target
/// paths, in-selection collision resolution, and already-imported markers.
///
/// Pure by construction: no filesystem access, no database, no actor, no
/// clock, no randomness. The preview re-runs `plan(...)` on every checkbox
/// toggle and hands the resulting `ImportPlan` straight to the applier, so
/// planning the same inputs twice must always produce the same output —
/// that equality is the entire dry-run promise. `nonCollidingURL` is
/// deliberately NOT used here: it resolves against files already on disk,
/// which is the applier's job (Task 11), not the planner's.
@MainActor
public enum ImportPlanner {
    public static func plan(items: [ImportItem],
                            vaultRoot: URL,
                            existingImportIDs: Set<String>) -> ImportPlan {
        var taken: Set<String> = []
        var planned: [PlannedItem] = []

        for item in items {
            let directory = containedDirectory(for: item.folderPath, under: vaultRoot)
            let stem = LoreStore.sanitized(item.title)
            let preferredName = stem + ".md"
            let firstChoice = directory.appendingPathComponent(preferredName)

            if existingImportIDs.contains(item.sourceID) {
                planned.append(PlannedItem(item: item, targetURL: firstChoice,
                                           disposition: .alreadyImported))
                continue
            }

            if taken.contains(firstChoice.path) {
                var candidate = firstChoice
                var counter = 2
                while taken.contains(candidate.path) {
                    candidate = directory.appendingPathComponent("\(stem) \(counter).md")
                    counter += 1
                }
                taken.insert(candidate.path)
                planned.append(PlannedItem(item: item, targetURL: candidate,
                                           disposition: .renamedToAvoidCollision(
                                               original: preferredName)))
            } else {
                taken.insert(firstChoice.path)
                planned.append(PlannedItem(item: item, targetURL: firstChoice,
                                           disposition: .create))
            }
        }
        return ImportPlan(items: planned)
    }

    /// Builds `vaultRoot/comp1/comp2/...` with every component sanitized AND
    /// guaranteed not to be a traversal segment.
    ///
    /// `LoreStore.sanitized` strips `/` and `:` but has no opinion on `.` —
    /// it exists to make a single path COMPONENT safe, and `.`/`..` are
    /// already valid, harmless component text in that context. It is this
    /// call site's job to reject them as directory names: a `folderPath` of
    /// `["..", "..", "etc"]` sanitizes to the same `[".." , "..", "etc"]`
    /// untouched, and `appendingPathComponent` would then walk the result
    /// straight out of the vault. Any component that sanitizes to `.` or
    /// `..` is replaced with a literal placeholder so it stays inert.
    private static func containedDirectory(for folderPath: [String], under vaultRoot: URL) -> URL {
        let directory = folderPath.reduce(vaultRoot) { partial, component in
            let sanitizedComponent = LoreStore.sanitized(component)
            let safeComponent = (sanitizedComponent == "." || sanitizedComponent == "..")
                ? "-" : sanitizedComponent
            return partial.appendingPathComponent(safeComponent)
        }
        // Defensive containment check: standardizing resolves any residual
        // `.`/`..` segments before comparing, so this only ever fires if the
        // per-component guard above had a gap — but the planner promising
        // "never a target outside the vault root" must hold even then.
        let standardizedDirectory = directory.standardizedFileURL
        let standardizedRoot = vaultRoot.standardizedFileURL
        guard standardizedDirectory.path == standardizedRoot.path
            || standardizedDirectory.path.hasPrefix(standardizedRoot.path + "/")
        else {
            return vaultRoot
        }
        return directory
    }
}
