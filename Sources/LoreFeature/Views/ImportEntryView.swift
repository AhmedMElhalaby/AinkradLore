import SwiftUI
import AinkradAppKit

/// The import surface: pick a source, review what would land, then land it.
///
/// Every state here is terminal-or-recoverable — there is no path that leaves
/// the user looking at a sheet with nothing to do, which is the failure mode
/// the wizard hit twice in the host.
struct ImportEntryView: View {
    @Bindable var coordinator: ImportCoordinator
    let theme: HostTheme
    let onClose: () -> Void

    var body: some View {
        Group {
            switch coordinator.state {
            case .choosingSource:
                sourcePicker
            case .scanning:
                AinkradEmptyState(
                    icon: "magnifyingglass",
                    title: "Reading the source…",
                    message: "Nothing is written to your vault until you approve it.")
            case .previewing(let selection):
                ImportPreviewSheet(
                    selection: selection,
                    onImport: { plan in Task { await coordinator.apply(plan) } },
                    onCancel: onClose)
            case .finished(let report):
                report_(report)
            case .failed(let message):
                AinkradEmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Import stopped",
                    message: message,
                    actionTitle: "Back",
                    action: coordinator.reset)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .background(theme.tokens.surface)
        .environment(\.ainkradTheme, theme.tokens)
    }

    /// Obsidian only, and it says so. Apple Notes is not offered as a disabled
    /// row: an affordance that cannot be used teaches the user it is broken.
    /// It appears when the source behind it does.
    private var sourcePicker: some View {
        AinkradEmptyState(
            icon: "square.and.arrow.down",
            title: "Import an Obsidian vault",
            message: "Lore copies the vault in, keeps your [[wikilinks]], and shows you "
                + "every file before anything is written. Notes you have already "
                + "imported are skipped.",
            actionTitle: "Choose vault…",
            action: coordinator.chooseObsidianVault)
    }

    /// Named with a trailing underscore to avoid colliding with the `report`
    /// value it renders.
    @ViewBuilder private func report_(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            Text(Self.headline(report))
                .font(.headline)
                .foregroundStyle(theme.tokens.foreground)
            // Skipped and failed are listed, never summarised away. A silent
            // partial import is the one outcome this whole milestone exists to
            // prevent — the user has to be able to see WHICH file did not make
            // it, not just that some number of them did not.
            List {
                ForEach(report.skipped, id: \.0) { id, reason in
                    line(id, reason, icon: "arrow.turn.down.right", tint: theme.tokens.foreground.opacity(0.6))
                }
                ForEach(report.failed, id: \.0) { id, reason in
                    line(id, reason, icon: "exclamationmark.circle", tint: .red)
                }
            }
            .listStyle(.plain)
            .opacity(report.skipped.isEmpty && report.failed.isEmpty ? 0 : 1)
            HStack {
                Spacer()
                AinkradButton(title: "Done", style: .primary, action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AinkradSpacing.lg)
    }

    private func line(_ id: String, _ reason: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AinkradSpacing.sm) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(id).foregroundStyle(theme.tokens.foreground)
                Text(reason).font(.caption)
                    .foregroundStyle(theme.tokens.foreground.opacity(0.7))
            }
        }
    }

    /// The counts the user is owed, in one sentence.
    ///
    /// `imported` mixes note and attachment URLs (an Obsidian vault imports its
    /// images as files in their own right), so this counts FILES written and
    /// says so, rather than claiming a note count it cannot substantiate.
    static func headline(_ report: ImportReport) -> String {
        var parts = ["\(report.imported.count) file\(report.imported.count == 1 ? "" : "s") imported"]
        if !report.skipped.isEmpty { parts.append("\(report.skipped.count) already imported") }
        if !report.failed.isEmpty { parts.append("\(report.failed.count) failed") }
        return parts.joined(separator: " · ")
    }
}
