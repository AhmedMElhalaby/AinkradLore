import Foundation

/// One thing Lore can be asked to do, as a VALUE.
///
/// ## Why a registry at all
///
/// Lore had four keyboard shortcuts, each implemented as a zero-sized `Button`
/// hidden in an overlay at the point of use: ⌘W inside `TabBarView`, ⌘N and ⌘\
/// inside `LoreRootView`'s sidebar header, Esc inside `DocumentPane`. That
/// works for four and collapses at fourteen — nothing can enumerate them, so
/// nothing can show the user what exists, nothing can check two commands have
/// not claimed the same key, and every new one is another hand-placed overlay
/// with its own dispatch-order trap to rediscover.
///
/// This type is the catalog. It deliberately holds NO action: a command is a
/// description (what it is called, what it costs to reach, when it applies),
/// and running one is `LoreCommandRunner`'s job. Keeping the two apart is what
/// lets the catalog be `Hashable` — which `AinkradCommandMenu` requires of its
/// items — and lets every rule below be asserted without a store, a view, or a
/// running app.
struct LoreCommand: Identifiable, Hashable {

    /// Stable identity. A raw `String` so a future persisted setting (a
    /// user-rebound key, a "recent commands" list) has something durable to
    /// name, rather than an index into an array that reorders.
    enum ID: String, CaseIterable, Hashable {
        case newNote, newFolder, chooseVault, importNotes
        case toggleSidebar, closeDocument, saveNow, undoDelete
        case findInDocument, findNext, findPrevious, replaceInDocument
        case rebuildIndex, toggleShowAllFiles
        case toggleOutline, toggleBacklinks
        case commandPalette, quickOpen
    }

    /// What a command needs in order to make sense.
    ///
    /// A command that cannot run is ABSENT from the palette rather than
    /// present and dead — the same rule `EditorMenuItems` already applies to
    /// Cut and Copy with no selection, and for the same reason: a list that
    /// offers what it cannot do teaches the wrong thing.
    enum Requirement: Hashable {
        /// Always available.
        case always
        /// Needs an open vault.
        case vault
        /// Needs a document open in the pane.
        case document
        /// Needs a delete that can still be undone.
        case undoableDelete
    }

    let id: ID
    let title: String
    let systemName: String
    let shortcut: LoreShortcut?
    let requires: Requirement

    /// The palette groups by this, so related commands sit together rather
    /// than in declaration order.
    let group: Group

    enum Group: String, Hashable, CaseIterable {
        case document = "Document"
        case vault = "Vault"
        case view = "View"
    }
}

/// A key equivalent, as a value that can be both DISPLAYED and BOUND.
///
/// Modelled here rather than reusing SwiftUI's `KeyEquivalent`/`EventModifiers`
/// so the catalog stays free of SwiftUI and can be asserted in a plain test —
/// and so `display` (the `⌘⇧O` string the palette and any future cheat-sheet
/// show) is derived from the same value the binding uses. Two hand-maintained
/// spellings of one shortcut is how a cheat-sheet starts lying.
struct LoreShortcut: Hashable {
    let key: Character
    let shift: Bool
    let option: Bool

    init(_ key: Character, shift: Bool = false, option: Bool = false) {
        self.key = key
        self.shift = shift
        self.option = option
    }

    /// Command is implied — every shortcut in Lore uses it, and a modifier
    /// that is always present is noise in the model.
    var display: String {
        var out = ""
        if option { out += "⌥" }
        if shift { out += "⇧" }
        out += "⌘"
        return out + String(key).uppercased()
    }
}

/// The catalog, and the rules for reading it.
enum LoreCommands {

    /// Every command Lore knows, in palette order within each group.
    ///
    /// Esc is deliberately ABSENT. It is not a command: it dismisses whatever
    /// is frontmost, it is claimed conditionally by `DocumentPane` precisely so
    /// it does not steal `cancelOperation` from the `[[`-completion popup, and
    /// modelling it here would invite exactly the unconditional binding that
    /// comment warns against.
    static let all: [LoreCommand] = [
        // Document
        .init(id: .newNote, title: "New Note", systemName: "plus",
              shortcut: LoreShortcut("n"), requires: .vault, group: .document),
        .init(id: .saveNow, title: "Save", systemName: "arrow.down.doc",
              shortcut: LoreShortcut("s"), requires: .document, group: .document),
        .init(id: .closeDocument, title: "Close Document", systemName: "xmark",
              shortcut: LoreShortcut("w"), requires: .document, group: .document),
        .init(id: .quickOpen, title: "Quick Open…", systemName: "doc.text.magnifyingglass",
              shortcut: LoreShortcut("p"), requires: .vault, group: .document),
        .init(id: .findInDocument, title: "Find…", systemName: "magnifyingglass",
              shortcut: LoreShortcut("f"), requires: .document, group: .document),
        .init(id: .findNext, title: "Find Next", systemName: "chevron.down",
              shortcut: LoreShortcut("g"), requires: .document, group: .document),
        .init(id: .findPrevious, title: "Find Previous", systemName: "chevron.up",
              shortcut: LoreShortcut("g", shift: true), requires: .document,
              group: .document),
        .init(id: .replaceInDocument, title: "Find and Replace…",
              systemName: "arrow.left.arrow.right",
              shortcut: LoreShortcut("f", option: true), requires: .document,
              group: .document),
        // Vault
        .init(id: .newFolder, title: "New Folder…", systemName: "folder.badge.plus",
              shortcut: nil, requires: .vault, group: .vault),
        .init(id: .importNotes, title: "Import…", systemName: "square.and.arrow.down",
              shortcut: nil, requires: .vault, group: .vault),
        .init(id: .chooseVault, title: "Choose Vault…", systemName: "folder",
              shortcut: nil, requires: .always, group: .vault),
        .init(id: .rebuildIndex, title: "Rebuild Index", systemName: "arrow.clockwise",
              shortcut: LoreShortcut("r"), requires: .vault, group: .vault),
        .init(id: .undoDelete, title: "Undo Delete", systemName: "arrow.uturn.backward",
              shortcut: LoreShortcut("z"), requires: .undoableDelete, group: .vault),
        // View
        .init(id: .toggleSidebar, title: "Toggle Sidebar", systemName: "sidebar.leading",
              shortcut: LoreShortcut("\\"), requires: .always, group: .view),
        .init(id: .toggleOutline, title: "Outline", systemName: "list.bullet.indent",
              shortcut: LoreShortcut("o", shift: true), requires: .document, group: .view),
        .init(id: .toggleBacklinks, title: "Linked Mentions", systemName: "link",
              shortcut: LoreShortcut("b", shift: true), requires: .document, group: .view),
        .init(id: .toggleShowAllFiles, title: "Show All Files", systemName: "eye",
              shortcut: nil, requires: .vault, group: .view),
        .init(id: .commandPalette, title: "Command Palette", systemName: "command",
              shortcut: LoreShortcut("k"), requires: .always, group: .view),
    ]

    /// The context a command is judged against — the four facts any command's
    /// availability can depend on, as a plain value so the filter is testable
    /// without a store.
    struct Context: Hashable {
        var hasVault: Bool
        var hasDocument: Bool
        var canUndoDelete: Bool

        static let empty = Context(hasVault: false, hasDocument: false,
                                   canUndoDelete: false)
    }

    /// Every command that can actually run right now.
    static func available(in context: Context) -> [LoreCommand] {
        all.filter { isAvailable($0, in: context) }
    }

    static func isAvailable(_ command: LoreCommand, in context: Context) -> Bool {
        switch command.requires {
        case .always: return true
        case .vault: return context.hasVault
        case .document: return context.hasDocument
        case .undoableDelete: return context.canUndoDelete
        }
    }

    /// Commands matching `query`, ranked.
    ///
    /// Two levels. First, WHERE the match lands: a prefix match outranks a
    /// mid-string one, so typing "out" reaches "Outline" rather than whatever
    /// merely contains those letters.
    ///
    /// Second — and this is the part a test had to find — ties break on
    /// CATALOG ORDER, not alphabetically. "New Note" and "New Folder…" both
    /// prefix-match "n", and sorting the tie by title puts Folder first purely
    /// because F precedes N. Nothing about that is meaningful to the person
    /// typing, who almost certainly meant the note. Declaration order in
    /// `all` is therefore priority order, and is curated as such: the first
    /// row is a decision, not an accident of the alphabet.
    static func matching(_ query: String, in context: Context) -> [LoreCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return available(in: context) }
        let order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
        return available(in: context)
            .compactMap { command -> (LoreCommand, Int)? in
                let title = command.title.lowercased()
                if title.hasPrefix(trimmed) { return (command, 0) }
                if title.contains(trimmed) { return (command, 1) }
                return nil
            }
            .sorted { ($0.1, order[$0.0.id] ?? 0) < ($1.1, order[$1.0.id] ?? 0) }
            .map(\.0)
    }

    /// The shortcut, if any, for one command — the single source both the
    /// binding and the palette's keycap read.
    static func shortcut(for id: LoreCommand.ID) -> LoreShortcut? {
        all.first { $0.id == id }?.shortcut
    }
}
