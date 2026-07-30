import XCTest
import SwiftUI
@testable import LoreFeature
import AinkradAppKit

/// The first-run path, which three milestones and 534 tests never touched.
///
/// Every other test in this suite reaches a working store through
/// `setVaultRootForTesting`, so *no* test had ever observed Lore with no vault
/// selected — the state a user is in the very first time they open it. Driving
/// the GUI found the consequence immediately: the "new note" button did
/// nothing at all, forever, with no error and no way forward.
///
/// Two independent defects produced that one symptom, and each gets a test
/// here:
///
///  - `create` throws `.noVault`, and the caller swallowed it with `try?`;
///  - the ONLY vault picker lived in `makeSettingsView`, a surface the Dev Host
///    never renders — so there was no reachable way to select a vault and clear
///    the condition.
@MainActor
final class NoVaultTests: XCTestCase {

    private func vaultlessStore() -> LoreStore {
        LoreStore(documents: FakeDocs(),
                  indexPath: FileManager.default.temporaryDirectory
                      .appendingPathComponent("\(UUID()).sqlite"))
    }

    private func tempVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-novault-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - The store's own contract

    /// The precondition the whole bug rests on. Asserted so that if `create`
    /// ever stops throwing here, the tests below are known to have gone vacuous.
    func test_createWithNoVaultThrowsNoVault() {
        XCTAssertThrowsError(try vaultlessStore().create(title: "")) { error in
            XCTAssertEqual(error as? LoreError, .noVault)
        }
    }

    /// `LoreStore.vaultRoot` is what the root view must branch on to know it is
    /// in the first-run state at all.
    func test_storeReportsNoVaultRootBeforeSelection() {
        XCTAssertNil(vaultlessStore().vaultRoot)
    }

    // MARK: - Defect 1: the silent swallow

    /// The reported symptom, at the layer that caused it.
    ///
    /// This was `try? store.create(title: "") else { return }` in
    /// `LoreRootView.quickCapture` — a click that could never succeed and never
    /// said why. `SidebarOperations.message` is the channel the sidebar already
    /// uses for a refused trash, for exactly this reason.
    func test_createDocumentSurfacesAMessageInsteadOfDoingNothing() {
        let ops = SidebarOperations(store: vaultlessStore())
        XCTAssertNil(ops.createDocument())
        let message = ops.message
        XCTAssertNotNil(message, "a create that cannot succeed must say so")
        XCTAssertTrue(message?.lowercased().contains("vault") == true,
                      "the message must name the actual cause, got: \(message ?? "nil")")
    }

    /// The success path still returns the new document, so the caller can open
    /// it. Guards against "fixing" the silence by making create always fail.
    func test_createDocumentReturnsTheNewDocumentAndSetsNoMessage() throws {
        let root = try tempVault()
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        let ops = SidebarOperations(store: store)

        let created = ops.createDocument()

        let url = try XCTUnwrap(created, "a create with a vault open must succeed")
        XCTAssertNil(ops.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "md")
    }

    // MARK: - Defect 2: no reachable way to select a vault

    /// The testable half of the picker, split from the `NSOpenPanel` exactly as
    /// `move(_:toFolder:)` is split from `beginMove`. Without this the Dev Host
    /// has no route to a vault at all.
    func test_selectVaultActivatesTheVaultAndClearsTheCondition() throws {
        let root = try tempVault()
        try "---\nid: a\ntitle: A\n---\nx".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let store = vaultlessStore()
        let ops = SidebarOperations(store: store)

        ops.selectVault(root)

        XCTAssertNil(ops.message)
        XCTAssertEqual(store.vaultRoot.map { VaultIndexCoordinator.canonical($0) },
                       VaultIndexCoordinator.canonical(root))
        // And the condition is genuinely cleared: create now works.
        XCTAssertNotNil(ops.createDocument())
    }

    /// A vault that cannot be activated must report, not vanish — the same rule
    /// the trash path already follows.
    func test_selectVaultReportsAFailureInsteadOfSwallowingIt() throws {
        let missing = try tempVault().appendingPathComponent("does-not-exist", isDirectory: true)
        let store = vaultlessStore()
        let ops = SidebarOperations(store: store)

        ops.selectVault(missing)

        XCTAssertNotNil(ops.message, "a vault that could not be opened must say so")
        XCTAssertNil(store.vaultRoot)
    }

    // MARK: - The empty state must not invite an impossible click

    /// With no vault, the root view used to render "No document open … press
    /// ⌘N to capture a new one" — advice that could not work. The view is only
    /// smoke-testable, so the branch is asserted on the value it is built from.
    func test_rootViewEmptyStateDistinguishesNoVaultFromNoDocument() throws {
        let store = vaultlessStore()
        XCTAssertEqual(LoreRootView.emptyState(for: store), .noVault)

        let root = try tempVault()
        let withVault = LoreStore(documents: FakeDocs(),
                                  indexPath: root.appendingPathComponent(".idx.sqlite"))
        try withVault.setVaultRootForTesting(root)
        XCTAssertEqual(LoreRootView.emptyState(for: withVault), .noDocument)
    }
}
