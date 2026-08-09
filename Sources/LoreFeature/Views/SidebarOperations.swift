import Foundation
import AppKit
import Observation

/// The state machine behind the sidebar's rename / move / trash affordances,
/// shared by BOTH sidebar modes (flat list and folder tree) so neither grows
/// its own copy of a destructive flow.
///
/// Deliberately a plain observable object rather than view state: SwiftUI is
/// only smoke-testable in this project, and the behaviour that matters here is
/// not layout. Three things in particular are asserted directly against this
/// type in `SidebarOperationsTests`:
///
///  - a plan carrying a `refusal` produces a preview that CANNOT be confirmed;
///  - a refused trash produces a visible `message` instead of vanishing;
///  - a move outside the vault root is refused before any plan is built.
@MainActor
@Observable
final class SidebarOperations {

    /// What a name prompt is currently naming.
    enum NameTarget: Equatable {
        case document(URL)
        case folder(URL)
        /// A NEW folder about to be created inside the associated parent —
        /// distinct from `.folder`, which names an EXISTING folder being
        /// renamed, because the two need different verbs and different store
        /// calls on confirm.
        case newFolder(URL)
    }

    /// The plan a preview is showing, kept so `confirm()` applies exactly the
    /// plan the user reviewed — never a freshly recomputed one. Recomputing at
    /// confirm time would silently re-read the plan-time mtime baselines, which
    /// is precisely what makes the "changed on disk" guard tautological.
    private enum Pending {
        case document(RenamePlan, isMove: Bool)
        case folder(FolderRenamePlan)
        case trashFolder(FolderTrashPlan)
    }

    private let store: LoreStore
    private var pending: Pending?

    /// Non-nil while the name prompt is up.
    var nameTarget: NameTarget?
    var nameText: String = ""
    /// Non-nil while the confirmation sheet is up.
    var preview: RenamePreview?
    /// Non-nil once the reviewed plan has been applied; the sheet reports it.
    var report: RenameReport?
    /// A refusal or failure with no sheet of its own — most importantly a
    /// REFUSED TRASH, which used to be a silent no-op (`try? store.trash(row)`).
    var message: String?
    /// The row a trash was requested for, awaiting confirmation.
    var pendingTrash: IndexRow?

    init(store: LoreStore) { self.store = store }

    // MARK: - Rename

    func beginRename(_ row: IndexRow) {
        nameTarget = .document(row.path)
        nameText = row.path.deletingPathExtension().lastPathComponent
    }

    func beginRenameFolder(_ folder: URL) {
        nameTarget = .folder(folder)
        nameText = folder.lastPathComponent
    }

    /// Asks for the name of a new folder inside `parent`. Unlike rename/move,
    /// there is nothing to preview here — creating an empty directory affects
    /// nothing else in the vault — so confirming the name sheet performs the
    /// create directly instead of routing through a plan/preview.
    func beginNewFolder(in parent: URL) {
        nameTarget = .newFolder(parent)
        nameText = ""
    }

    /// Turns the typed name into a PLAN and a preview for the `.document` and
    /// `.folder` (rename) targets — those two never write, a refusal (empty
    /// name, path separator, `..`, escape from the vault, destination exists)
    /// arriving on the plan and rendered instead of a preview. `.newFolder` is
    /// NOT plan-and-preview: it calls `store.createFolder` directly and does
    /// write a real directory immediately (see `beginNewFolder`'s doc comment
    /// on why folder creation skips the plan/preview step the other two use).
    func commitName() {
        guard let target = nameTarget else { return }
        nameTarget = nil
        switch target {
        case .document(let url):
            let plan = store.plan(rename: url, to: nameText)
            pending = .document(plan, isMove: false)
            preview = RenamePreview(document: plan, isMove: false)
        case .folder(let url):
            let plan = store.plan(renameFolder: url, to: nameText)
            pending = .folder(plan)
            preview = RenamePreview(folder: plan)
        case .newFolder(let parent):
            do {
                let created = try store.createFolder(named: nameText, in: parent)
                message = "Created “\(created.lastPathComponent)”."
            } catch let error as LoreError {
                message = Self.describeCreateFolder(error)
            } catch {
                message = "The folder could not be created: \(error.localizedDescription)"
            }
        }
    }

    /// `describeCreate` phrases everything as a failed document create, so
    /// folder creation gets its own sentences — the errors that can actually
    /// reach it (`invalidName`, `alreadyExists`, `outsideVault`) barely
    /// overlap with the document-create ones anyway.
    static func describeCreateFolder(_ error: LoreError) -> String {
        switch error {
        case .invalidName(let name):
            return "“\(name)” is not a valid folder name. "
                + "Folder names cannot be empty, cannot contain “/” or “:”, cannot start "
                + "with “.”, and cannot contain control characters."
        case .alreadyExists(let url):
            return "A folder named “\(url.lastPathComponent)” already exists here."
        case .outsideVault(let url):
            return "“\(url.lastPathComponent)” is outside the vault, so nothing was created."
        case .noVault:
            return "No vault is open, so there is nowhere to put a new folder."
        case .trashFailed(_, let reason), .unsavedEdits(_, let reason):
            return "The folder could not be created: \(reason)"
        case .externalChange(let url):
            return "“\(url.lastPathComponent)” changed outside Lore, so nothing was created."
        case .notARegularFile:
            // Not reachable from `createFolder` — raised only by
            // `writeAttachment(copying:besideNote:)` — kept for the same
            // reason the other unreachable cases are kept.
            return "The folder could not be created."
        }
    }

    func cancelName() { nameTarget = nil }

    // MARK: - Vault selection

    /// Asks for a vault folder, then opens it.
    ///
    /// Lore's only vault picker used to live in `makeSettingsView`. The Dev
    /// Host renders `makeRootView` and nothing else, so under it there was no
    /// reachable way to select a vault — and every affordance that needs one
    /// (create, search, the whole sidebar) was permanently inert with no
    /// explanation. A first-run action belongs on the surface the user is
    /// actually looking at.
    func beginChooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open vault"
        panel.message = "Choose the folder that holds your notes."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        selectVault(folder)
    }

    /// The testable half: open `folder` as the vault, reporting any failure.
    ///
    /// `LoreSettingsView.pickFolder` did this as `try? store.setVaultRoot(url)`
    /// — so a vault that could not be bookmarked or indexed left the user
    /// looking at an unchanged, empty window with nothing said. Same class of
    /// defect as the swallowed create below, on the step immediately before it.
    func selectVault(_ folder: URL) {
        do {
            try store.setVaultRoot(folder)
            message = nil
        } catch {
            message = "“\(folder.lastPathComponent)” could not be opened as a vault: "
                + error.localizedDescription
        }
    }

    // MARK: - Create

    /// Creates an untitled document and returns its URL, or nil having set
    /// `message` to the reason it could not.
    ///
    /// The reported bug: `LoreRootView.quickCapture` was
    /// `guard let note = try? store.create(title: "") else { return }`. With no
    /// vault open `create` throws `.noVault`, `try?` discarded it, and the
    /// button did nothing — indistinguishable from a dead button, which is
    /// precisely how it was reported. This is the same fix, and the same
    /// reasoning, already written down for delete in `deleteDocument`.
    @discardableResult
    func createDocument() -> URL? {
        do {
            let note = try store.create(title: "")
            message = nil
            return note.path
        } catch let error as LoreError {
            message = Self.describeCreate(error)
            return nil
        } catch {
            message = "The document could not be created: \(error.localizedDescription)"
            return nil
        }
    }

    /// `describe(_:row:)` phrases everything as a failed DELETE and needs a row
    /// that does not exist yet, so create gets its own sentences.
    static func describeCreate(_ error: LoreError) -> String {
        switch error {
        case .noVault:
            return "No vault is open, so there is nowhere to put a new document. "
                + "Choose a vault folder first."
        case .outsideVault(let url):
            return "A new document would have been written outside the vault "
                + "(“\(url.lastPathComponent)”), so nothing was created."
        case .trashFailed(_, let reason), .unsavedEdits(_, let reason):
            return "The document could not be created: \(reason)"
        case .externalChange(let url):
            return "“\(url.lastPathComponent)” changed outside Lore, so nothing was created."
        case .invalidName, .alreadyExists:
            // Not reachable from a document create — those errors are raised
            // only by `createFolder` — but the switch is exhaustive on
            // purpose, so this says something true rather than nothing.
            return "The document could not be created."
        case .notARegularFile:
            // Not reachable from a document create — raised only by
            // `writeAttachment(copying:besideNote:)` — kept for the same
            // reason as `invalidName`/`alreadyExists` above.
            return "The document could not be created."
        }
    }

    /// The user-facing sentence for a failed paste-image or drop-file
    /// attachment write (`LoreStore.writeAttachment`'s two overloads).
    ///
    /// Whole-branch review round 3, Important 3: `DocumentPane` used to
    /// format these with bare `error.localizedDescription`. That reads fine
    /// for a genuine `NSError` (`Data.write` on the paste path throws a real
    /// `CocoaError` with a real message), but `LoreError` — thrown by both
    /// overloads' own guards — is a plain `Error, Equatable` with no
    /// `LocalizedError` conformance, so the SAME formatting produced
    /// `"The operation couldn't be completed. (LoreFeature.LoreError error
    /// 8.)"` for exactly the case this wave's directory-drop guard exists to
    /// explain. `LoreError` cases get the same hand-written treatment
    /// `describeCreate`/`describeCreateFolder` already give the errors THEY
    /// see; anything else (a `CocoaError` from the underlying write, a
    /// filesystem error from `copyItem`) falls back to its own
    /// `localizedDescription`, which is reliable for those types.
    static func describeAttachmentWrite(_ error: Error) -> String {
        guard let loreError = error as? LoreError else {
            return error.localizedDescription
        }
        switch loreError {
        case .notARegularFile(let url):
            return "“\(url.lastPathComponent)” is a folder, not a file, so it "
                + "was not added. Only individual files can be attached."
        case .outsideVault(let url):
            return "“\(url.lastPathComponent)” would have been written outside "
                + "the vault, so nothing was added."
        case .noVault:
            return "No vault is open, so there is nowhere to put the attachment."
        case .externalChange(let url):
            return "“\(url.lastPathComponent)” changed outside Lore, so nothing was added."
        case .trashFailed(_, let reason), .unsavedEdits(_, let reason):
            return "The attachment could not be added: \(reason)"
        case .invalidName, .alreadyExists:
            // Not reachable from an attachment write — raised only by
            // `createFolder` — kept for the same reason the other
            // "not reachable" arms in this file are kept.
            return "The attachment could not be added."
        }
    }

    // MARK: - Move

    /// Asks for a destination folder, then previews the move. The panel opens
    /// AT the vault root, but a panel can be navigated anywhere, so the choice
    /// is validated rather than trusted — see `move(_:toFolder:)`.
    func beginMove(_ row: IndexRow) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move here"
        panel.directoryURL = store.vaultRoot
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        move(row, toFolder: folder)
    }

    /// The testable half of the move: validate the destination, then plan.
    ///
    /// A destination outside the vault is refused HERE, with a message, rather
    /// than planned: the store would happily move the file, but its inbound
    /// links have no vault-relative path to be rewritten to, so every
    /// explicit-path link to it breaks and the file leaves the index.
    func move(_ row: IndexRow, toFolder folder: URL) {
        guard let root = store.vaultRoot else {
            message = "No vault is open."
            return
        }
        let rootComponents = VaultIndexCoordinator.canonical(root).pathComponents
        let destination = VaultIndexCoordinator.canonical(folder)
        guard Array(destination.pathComponents.prefix(rootComponents.count)) == rootComponents else {
            message = "“\(folder.lastPathComponent)” is outside the vault. "
                + "Lore can only move documents to folders inside it."
            return
        }
        guard destination.path != VaultIndexCoordinator.canonical(row.path)
                .deletingLastPathComponent().path else {
            message = "“\(row.path.lastPathComponent)” is already in that folder."
            return
        }
        let plan = store.plan(move: row.path, toFolder: destination)
        pending = .document(plan, isMove: true)
        preview = RenamePreview(document: plan, isMove: true)
    }

    // MARK: - Confirming

    /// Applies the reviewed plan. Only reachable when `preview.canConfirm`.
    func confirm() {
        guard let pending, preview?.canConfirm == true else { return }
        switch pending {
        case .document(let plan, let isMove):
            let result = store.apply(plan)
            report = result
            // Only an actual RENAME (basename change) needs the title synced
            // — a plain move to another folder (`isMove`) keeps its name, so
            // its title (already equal to that name) is untouched. Only on
            // full success: a partial rename (e.g. the move itself failed,
            // or the destination was left at the source because of a
            // refusal) must not go patch a title onto a file that never
            // actually got the new name.
            if !isMove, let moved = result.movedTo, result.failed.isEmpty {
                store.syncTitleAfterFileRename(at: moved)
            }
        case .folder(let plan): report = store.apply(plan)
        case .trashFolder(let plan):
            // No `RenameReport` here — `applyTrashFolder` isn't a link
            // rewrite, it's a move-to-Trash, so it reports through `message`
            // exactly like single-document trash's `confirmTrash` does,
            // rather than forcing its result through a report shape built for
            // rewritten/skipped/unchanged files.
            preview = nil
            do {
                let count = try store.applyTrashFolder(plan)
                message = "Moved “\(plan.folder.lastPathComponent)” to the Trash "
                    + "(\(count) document\(count == 1 ? "" : "s"))."
            } catch let error as LoreError {
                message = Self.describe(error, folder: plan.folder)
            } catch {
                message = "The folder could not be moved to the Trash: "
                    + error.localizedDescription
            }
            self.pending = nil
            return
        }
        self.pending = nil
    }

    /// The user-facing sentence for each way a folder trash can be declined.
    static func describe(_ error: LoreError, folder: URL) -> String {
        let name = folder.lastPathComponent
        switch error {
        case .trashFailed(_, let reason):
            return "“\(name)” could not be moved to the Trash: \(reason) "
                + "Nothing was deleted — Lore never falls back to deleting it permanently."
        case .noVault:
            return "No vault is open, so nothing was deleted."
        // Reachable: `applyTrashFolder` refuses per-session, before touching
        // anything, when a tab under the folder is dirty and its flush fails
        // — same rule and same reason as single-document `LoreStore.trash`.
        case .unsavedEdits(_, let reason):
            return "“\(name)” was not deleted because \(reason)"
        // Reachable: `applyTrashFolder`'s own containment guard throws this
        // for the vault root itself or a target outside the vault, in case a
        // stale or forged plan reaches here without going through
        // `planTrashFolder`'s own refusal.
        case .outsideVault:
            return "“\(name)” was not deleted: it is the vault's own folder, or outside "
                + "the vault entirely."
        case .externalChange, .invalidName, .alreadyExists, .notARegularFile:
            // Not reachable from `applyTrashFolder` — kept for the same reason
            // the single-document `describe(_:row:)` keeps its own unreachable
            // cases: a true sentence rather than a silent gap in the switch.
            return "“\(name)” was not deleted."
        }
    }

    /// Dismisses the sheet in either of its states.
    func dismiss() {
        preview = nil
        report = nil
        pending = nil
    }

    // MARK: - Trash

    /// Asks for confirmation. The inbound-link count is read BEFORE the delete
    /// (afterwards there is nothing to count) and stated when non-zero: those
    /// links are deliberately NOT rewritten, so the user must know they will
    /// stop resolving.
    func requestTrash(_ row: IndexRow) { pendingTrash = row }

    /// Plans a recursive folder trash and shows it through the SAME `.preview`
    /// sheet single/folder rename uses — a destructive, recursive operation
    /// gets the full preview treatment (document count, inbound link count),
    /// not the one-line confirm dialog a single document gets.
    func requestTrashFolder(_ folder: URL) {
        let plan = store.planTrashFolder(folder)
        pending = .trashFolder(plan)
        preview = RenamePreview(trashFolder: plan)
    }

    func trashMessage(for row: IndexRow) -> String {
        let name = row.title.isEmpty ? row.path.lastPathComponent : row.title
        var text = "Move “\(name)” to the Trash?"
        let inbound = store.inboundLinkCount(to: row.path)
        if inbound > 0 {
            text += " \(inbound) note\(inbound == 1 ? "" : "s") link here. "
                + "Their links will stop resolving, and are not rewritten."
        }
        return text
    }

    /// Performs the delete, SURFACING every refusal.
    ///
    /// The previous implementation was `try? store.trash(row)`. `trash` refuses
    /// when a tab still holds unsaved edits it could not flush — so the user
    /// pressed Delete, nothing happened, and nothing said why. A refusal the
    /// user cannot see is indistinguishable from a broken button, and the
    /// obvious next move (press it again, harder) never works.
    func confirmTrash() {
        guard let row = pendingTrash else { return }
        pendingTrash = nil
        // One implementation, in `deleteDocument`, which the store-level test
        // drives directly.
        message = deleteDocument(row, in: store)
    }

    func cancelTrash() { pendingTrash = nil }

    /// The user-facing sentence for each way a delete can be declined. Pure, so
    /// it is asserted directly rather than through a view.
    static func describe(_ error: LoreError, row: IndexRow) -> String {
        let name = row.path.lastPathComponent
        switch error {
        case .unsavedEdits(_, let reason):
            // `reason` already names the unsaved edits AND the way out
            // (reload, overwrite, or save a copy) — see `LoreStore.trash`.
            return "“\(name)” was not deleted because \(reason)"
        case .trashFailed(_, let reason):
            return "“\(name)” could not be moved to the Trash: \(reason) "
                + "Nothing was deleted — Lore never falls back to deleting it permanently."
        case .noVault:
            return "No vault is open, so nothing was deleted."
        case .externalChange:
            return "“\(name)” changed outside Lore, so nothing was deleted. "
                + "Resolve it in the open tab, then delete it again."
        case .outsideVault(let url):
            // Not reachable from a delete — `outsideVault` is raised only by
            // `create` — but the switch is exhaustive on purpose, so this says
            // something true rather than nothing.
            return "“\(url.lastPathComponent)” is outside the vault, so nothing was deleted."
        case .invalidName, .alreadyExists, .notARegularFile:
            // Not reachable from a document delete either — raised only by
            // `createFolder` / `writeAttachment(copying:besideNote:)` — kept
            // for the same reason as `outsideVault` above.
            return "“\(name)” was not deleted."
        }
    }
}
