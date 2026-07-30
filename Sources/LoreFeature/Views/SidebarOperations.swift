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
    }

    /// The plan a preview is showing, kept so `confirm()` applies exactly the
    /// plan the user reviewed — never a freshly recomputed one. Recomputing at
    /// confirm time would silently re-read the plan-time mtime baselines, which
    /// is precisely what makes the "changed on disk" guard tautological.
    private enum Pending {
        case document(RenamePlan, isMove: Bool)
        case folder(FolderRenamePlan)
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

    /// Turns the typed name into a PLAN and a preview. Never writes. A refusal
    /// (empty name, path separator, `..`, escape from the vault, destination
    /// exists) arrives on the plan and is rendered instead of a preview.
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
        }
    }

    func cancelName() { nameTarget = nil }

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
        case .document(let plan, _): report = store.apply(plan)
        case .folder(let plan): report = store.apply(plan)
        }
        self.pending = nil
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
        }
    }
}
