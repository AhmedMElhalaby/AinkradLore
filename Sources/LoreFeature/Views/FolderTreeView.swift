import SwiftUI
import AinkradAppKit

/// A folder and everything directly inside it. Pure value built from index
/// rows, so the grouping logic is testable without a view host.
struct FolderNode: Identifiable {
    let id: String
    let name: String
    let children: [FolderNode]
    let documents: [IndexRow]

    static func tree(from rows: [IndexRow], root: URL) -> FolderNode {
        let rootDepth = root.standardizedFileURL.pathComponents.count
        var byFolder: [String: [IndexRow]] = [:]
        for row in rows {
            let parts = row.path.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            let folder = parts.dropLast().joined(separator: "/")
            byFolder[folder, default: []].append(row)
        }
        return node(named: "", path: "", byFolder: byFolder)
    }

    private static func node(named name: String, path: String,
                             byFolder: [String: [IndexRow]]) -> FolderNode {
        let childNames = Set(byFolder.keys.compactMap { key -> String? in
            guard key != path else { return nil }
            let prefix = path.isEmpty ? "" : path + "/"
            guard key.hasPrefix(prefix) else { return nil }
            return String(key.dropFirst(prefix.count)).split(separator: "/").first.map(String.init)
        }).sorted()

        return FolderNode(
            id: path.isEmpty ? "/" : path,
            name: name,
            children: childNames.map {
                node(named: $0, path: path.isEmpty ? $0 : path + "/" + $0, byFolder: byFolder)
            },
            documents: (byFolder[path] ?? []).sorted { $0.title < $1.title })
    }
}

/// Folder tree rendering of `store.rows`, an alternative to `NoteListView`'s
/// flat list. Expansion state and the choice between the two views persist
/// via `LoreStore`; see `LoreStore.sidebarMode` / `setExpandedFolders`.
///
/// Rename / move / trash arrive through `ops`, whose menus (`LoreRowMenu`,
/// `LoreFolderMenu`) are shared with `NoteListView` so a destructive affordance
/// is not defined twice.
struct FolderTreeView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @Binding var selected: IndexRow?
    let onSelect: (IndexRow) -> Void
    let ops: SidebarOperations
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let root = store.vaultRoot {
                    outline(FolderNode.tree(from: store.rows, root: root), depth: 0)
                }
            }
        }
        .onAppear { expanded = store.expandedFolders }
    }

    private func outline(_ node: FolderNode, depth: Int) -> AnyView {
        AnyView(outlineBody(node, depth: depth))
    }

    @ViewBuilder
    private func outlineBody(_ node: FolderNode, depth: Int) -> some View {
        if depth > 0 {
            Button {
                if expanded.contains(node.id) { expanded.remove(node.id) }
                else { expanded.insert(node.id) }
                store.setExpandedFolders(expanded)
            } label: {
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradIconGlyph(systemName: expanded.contains(node.id)
                                     ? "chevron.down" : "chevron.right")
                    Text(node.name)
                }
                .padding(.leading, CGFloat(depth) * 12)
            }
            .buttonStyle(.plain)
            // Only a real folder gets a folder menu. `node.id` is a
            // vault-RELATIVE path, so it is resolved against the live vault root
            // rather than assumed absolute; with no vault there is no folder to
            // rename and the menu is simply absent.
            .contextMenu {
                if let folder = folderURL(node) { LoreFolderMenu(folder: folder, ops: ops) }
            }
        }
        if depth == 0 || expanded.contains(node.id) {
            ForEach(node.documents, id: \.path) { row in
                AinkradListRow(
                    isSelected: selected?.path == row.path,
                    onTap: { selected = row; onSelect(row) },
                    leading: { AinkradIconGlyph(systemName: icon(for: row)) },
                    title: row.title.isEmpty ? row.path.lastPathComponent : row.title,
                    subtitle: nil,
                    trailing: { EmptyView() })
                .padding(.leading, CGFloat(depth + 1) * 12)
                .contextMenu { LoreRowMenu(row: row, ops: ops) }
            }
            ForEach(node.children) { child in outline(child, depth: depth + 1) }
        }
    }

    /// The absolute URL of a tree node, or nil for the synthetic root node (its
    /// id is `"/"` and it IS the vault — renaming it is not a folder rename).
    private func folderURL(_ node: FolderNode) -> URL? {
        guard let root = store.vaultRoot, node.id != "/" else { return nil }
        return root.appendingPathComponent(node.id)
    }

    private func icon(for row: IndexRow) -> String {
        row.type == EngineRegistry.unclaimedType ? "doc" : "doc.text"
    }
}
