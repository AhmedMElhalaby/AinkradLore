import SwiftUI
import AinkradAppKit

/// Everything the confirmation sheet renders, derived from a plan and nothing
/// else. A pure value, so the wording and — more importantly — the
/// `canConfirm` decision are testable without a view host.
///
/// M1 HAS NO UNDO. The preview is the entire safety net for a bulk mutation, so
/// `canConfirm` is false whenever the plan carries a `refusal`: a refused plan
/// must never be reachable through a confirm button, because `apply` would
/// dutifully report the refusal as a failure and the user would have pressed a
/// destructive-looking button for nothing.
struct RenamePreview {
    let title: String
    let summary: String
    /// Non-nil when the plan was refused at plan time (invalid name, path
    /// traversal, destination exists, parent missing or unwritable). Shown
    /// INSTEAD of a preview.
    let refusal: String?
    let editCount: Int
    let files: [URL]
    let confirmTitle: String

    var canConfirm: Bool { refusal == nil }

    // MARK: - From the two plan types

    init(document plan: RenamePlan, isMove: Bool) {
        let name = plan.source.lastPathComponent
        title = isMove ? "Move “\(name)”" : "Rename “\(name)”"
        confirmTitle = isMove ? "Move" : "Rename"
        refusal = plan.refusal
        editCount = plan.edits.count
        files = plan.affectedFiles
        let action = isMove
            ? "move it to \(plan.destination.deletingLastPathComponent().lastPathComponent)"
            : "rename it to “\(plan.destination.lastPathComponent)”"
        if plan.refusal != nil {
            summary = ""
        } else if plan.edits.isEmpty {
            summary = "No other document links to this, so no links need updating. "
                + "Lore will \(action)."
        } else {
            summary = "This will update \(Self.count(plan.edits.count, "link")) across "
                + "\(Self.count(plan.affectedFiles.count, "file")), then \(action)."
        }
    }

    init(folder plan: FolderRenamePlan) {
        title = "Rename folder “\(plan.source.lastPathComponent)”"
        confirmTitle = "Rename folder"
        refusal = plan.refusal
        editCount = plan.edits.count
        files = plan.affectedFiles
        if plan.refusal != nil {
            summary = ""
        } else if plan.hasNoIndexedDocuments {
            // NOT "nothing to do": the directory still moves, and every
            // unindexed file inside it travels along. Saying "no changes" here
            // would describe a real mutation as a no-op.
            summary = "This folder holds no indexed documents. It will still be renamed "
                + "to “\(plan.destination.lastPathComponent)”, and everything inside it — "
                + "including files Lore does not index — moves with it."
        } else if plan.edits.isEmpty {
            summary = "\(Self.count(plan.documentMoves.count, "document").capitalizedFirst) "
                + "will move with the folder. No inbound links need updating."
        } else {
            summary = "\(Self.count(plan.documentMoves.count, "document").capitalizedFirst) "
                + "will move with the folder. This will update "
                + "\(Self.count(plan.edits.count, "link")) across "
                + "\(Self.count(plan.affectedFiles.count, "file"))."
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

/// Confirms a bulk mutation before anything is written, and — after it has run
/// — reports what actually happened.
///
/// Two states in one sheet on purpose: the apply happens between them, and the
/// user who confirmed a change is exactly the user who needs to be told that
/// three of its files were left alone. A separate, dismissible report is a
/// report nobody reads.
struct RenamePreviewSheet: View {
    let preview: RenamePreview
    /// Non-nil once the plan has been applied: the sheet switches to reporting.
    let report: RenameReport?
    let theme: HostTheme
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            Text(report == nil ? preview.title : "Done").font(.headline)
                .foregroundStyle(theme.tokens.foreground)
            if let report {
                reportBody(report)
            } else {
                planBody
            }
            HStack {
                Spacer()
                if report != nil {
                    AinkradButton(title: "Close", style: .primary, action: onCancel)
                } else if preview.canConfirm {
                    AinkradButton(title: "Cancel", style: .ghost, action: onCancel)
                    AinkradButton(title: preview.confirmTitle, style: .primary,
                                  action: onConfirm)
                } else {
                    // No confirm button at all for a refused plan.
                    AinkradButton(title: "OK", style: .primary, action: onCancel)
                }
            }
        }
        .padding(AinkradSpacing.lg)
        .frame(width: 460)
        .background(theme.tokens.surface)
        .environment(\.ainkradTheme, theme.tokens)
    }

    @ViewBuilder private var planBody: some View {
        if let refusal = preview.refusal {
            Text(refusal).foregroundStyle(theme.tokens.foreground)
        } else {
            Text(preview.summary).foregroundStyle(theme.tokens.foreground.opacity(0.85))
            if preview.files.isEmpty {
                EmptyView()
            } else {
                fileList(preview.files.map(\.lastPathComponent))
            }
        }
    }

    @ViewBuilder private func reportBody(_ report: RenameReport) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            Text(report.headline).foregroundStyle(theme.tokens.foreground)
            ForEach(Array(report.detailLines.enumerated()), id: \.offset) { line in
                Text(line.element)
                    .foregroundStyle(theme.tokens.foreground.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fileList(_ names: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(names.enumerated()), id: \.offset) { name in
                    Text(name.element).lineLimit(1)
                        .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 200)
    }
}
