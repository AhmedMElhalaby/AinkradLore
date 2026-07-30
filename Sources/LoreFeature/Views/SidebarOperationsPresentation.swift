import SwiftUI
import AinkradAppKit

/// Every modal the sidebar's rename / move / trash flows need, attached in ONE
/// place so both sidebar modes get identical behaviour and `LoreRootView` stays
/// under the project's line ceiling.
///
/// A single `.sheet` driven by `SidebarOperations.activeSheet` rather than three
/// stacked `.sheet` modifiers: more than one sheet attached to the same view is
/// unreliable on macOS, and the failure mode is a dialog that silently never
/// appears — which, for a confirmation dialog guarding an irreversible bulk
/// mutation, is the worst possible way to fail.
extension View {
    func loreSidebarOperations(_ ops: SidebarOperations, theme: HostTheme) -> some View {
        self
            .sheet(isPresented: Binding(
                get: { ops.activeSheet != nil },
                set: { if !$0 { ops.dismissAll() } })) {
                    SidebarOperationSheet(ops: ops, theme: theme)
                }
            .ainkradConfirmDialog(
                isPresented: Binding(get: { ops.pendingTrash != nil },
                                     set: { if !$0 { ops.cancelTrash() } }),
                title: "Move to Trash",
                message: ops.pendingTrash.map { ops.trashMessage(for: $0) } ?? "",
                confirmTitle: "Move to Trash",
                isDestructive: true) { ops.confirmTrash() }
    }
}

/// Resolves `activeSheet` to the right content.
struct SidebarOperationSheet: View {
    @Bindable var ops: SidebarOperations
    let theme: HostTheme

    var body: some View {
        switch ops.activeSheet {
        case .name:
            NameSheet(title: ops.nameTargetTitle, text: $ops.nameText, theme: theme,
                      onConfirm: { ops.commitName() }, onCancel: { ops.cancelName() })
        case .preview:
            if let preview = ops.preview {
                RenamePreviewSheet(preview: preview, report: ops.report, theme: theme,
                                   onConfirm: { ops.confirm() }, onCancel: { ops.dismiss() })
            }
        case .message:
            MessageSheet(text: ops.message ?? "", theme: theme) { ops.message = nil }
        case nil:
            EmptyView()
        }
    }
}

/// Asks for a new name. Nothing is planned until Continue: this collects text,
/// and the store decides whether the text is a NAME (see
/// `LoreStore.nameRejection`) — this sheet deliberately does not pre-judge it,
/// so there is exactly one place that rule lives.
struct NameSheet: View {
    let title: String
    @Binding var text: String
    let theme: HostTheme
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            Text(title).font(.headline).foregroundStyle(theme.tokens.foreground)
            TextField("New name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onConfirm)
            Text("You will see exactly what changes before anything is written.")
                .foregroundStyle(theme.tokens.foreground.opacity(0.7))
            HStack {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost, action: onCancel)
                AinkradButton(title: "Continue", style: .primary, action: onConfirm)
            }
        }
        .padding(AinkradSpacing.lg)
        .frame(width: 420)
        .background(theme.tokens.surface)
        .environment(\.ainkradTheme, theme.tokens)
    }
}

/// A refusal or failure the user must see. Exists because the alternative —
/// which is what shipped before this task — was `try?`.
struct MessageSheet: View {
    let text: String
    let theme: HostTheme
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            Text("Not done").font(.headline).foregroundStyle(theme.tokens.foreground)
            Text(text).foregroundStyle(theme.tokens.foreground.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); AinkradButton(title: "OK", style: .primary, action: onDismiss) }
        }
        .padding(AinkradSpacing.lg)
        .frame(width: 420)
        .background(theme.tokens.surface)
        .environment(\.ainkradTheme, theme.tokens)
    }
}

/// The document row menu, defined ONCE and used by both sidebar modes: a
/// destructive affordance that differs between two views is a destructive
/// affordance that was reviewed once.
///
/// Unclaimed rows (`.pdf`, `.xlsx`, anything no engine claims) get Rename and
/// Move but NO Delete, exactly as the previous milestone left them: Lore cannot
/// open them, so it does not arm an irreversible delete against a binary the
/// user has no way to inspect here first.
struct LoreRowMenu: View {
    let row: IndexRow
    let ops: SidebarOperations

    var body: some View {
        Button("Rename…") { ops.beginRename(row) }
        Button("Move to…") { ops.beginMove(row) }
        if row.type != EngineRegistry.unclaimedType {
            Divider()
            Button("Move to Trash", role: .destructive) { ops.requestTrash(row) }
        }
    }
}

/// The folder row menu. Rename only: renaming a folder is one directory move
/// with a full preview behind it, whereas creating and trashing folders have no
/// store API yet — and inventing one inside a UI task is how an unreviewed
/// data-loss path gets added. See the task report.
struct LoreFolderMenu: View {
    let folder: URL
    let ops: SidebarOperations

    var body: some View {
        Button("Rename Folder…") { ops.beginRenameFolder(folder) }
    }
}

extension SidebarOperations {
    enum Sheet { case name, preview, message }

    /// Ordered by urgency, and mutually exclusive by construction: only one of
    /// these three states is ever set at a time by the flows above.
    var activeSheet: Sheet? {
        if nameTarget != nil { return .name }
        if preview != nil { return .preview }
        if message != nil { return .message }
        return nil
    }

    var nameTargetTitle: String {
        switch nameTarget {
        case .document(let url): "Rename “\(url.lastPathComponent)”"
        case .folder(let url): "Rename folder “\(url.lastPathComponent)”"
        case nil: ""
        }
    }

    /// Dismissing the sheet must clear whichever state opened it — otherwise the
    /// same sheet reopens on the next render.
    func dismissAll() {
        cancelName()
        dismiss()
        message = nil
    }
}
