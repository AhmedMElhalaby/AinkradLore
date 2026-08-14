import CoreGraphics
import AinkradAppKit

/// Lore's own geometry, in one value — the numbers that are about LORE's
/// layout rather than about the design system's scale.
///
/// The rule this file encodes: if a number appears in more than one view, or
/// answers a question someone could reasonably ask ("how wide is the
/// sidebar?", "how round are our chamfers?"), it belongs here. If it is a
/// one-off inside a single view, it stays there with a comment.
///
/// `LoreSidebarMetrics` already did this for the sidebar's indent and is left
/// alone: it is the pure, directly-asserted rule about how folder and document
/// rows line up, and folding it in here would bury it.
enum LoreMetrics {

    /// The sidebar's width.
    ///
    /// Still fixed — making it draggable and persisted is its own task — but
    /// no longer a bare `280` sitting in `LoreRootView`'s body next to an
    /// unrelated `.frame`.
    static let sidebarWidth: CGFloat = 280

    /// Horizontal padding for Lore's own bars (the document header, the panel
    /// bar), so the editor's chrome lines up column-to-column.
    static let gutter: CGFloat = AinkradSpacing.md

    /// The one chamfer cut Lore draws.
    ///
    /// There were two — `ChamferShape(cut: 6)` on tabs and `cut: 4` on the
    /// panel-bar buttons — with no rule distinguishing them; they were simply
    /// written at different times. Two chamfer radii in one window read as a
    /// mistake rather than a hierarchy, so there is now one.
    static let chamfer: CGFloat = 6

    /// Height of the tab strip. Tall enough that a `.sm`-padded tab plus its
    /// chamfer sits fully INSIDE the bar — at the old 32 the chamfer was
    /// clipped by the bar's own edge.
    static let tabBarHeight: CGFloat = 40
}
