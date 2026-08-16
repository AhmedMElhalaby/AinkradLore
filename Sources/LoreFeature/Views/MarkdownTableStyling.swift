import AppKit
import SwiftUI
import AinkradAppKit

/// Column alignment for pipe tables.
///
/// ## Why kerning, and not the two obvious alternatives
///
/// An `NSTextAttachment` is how most editors render a table, and it is ruled
/// out here: an attachment needs a `U+FFFC` character standing in for the
/// source, which changes the document's text and with it every offset the
/// index, the link graph and the MCP tools hold. That rule is the one this
/// codebase protects hardest.
///
/// `NSTextTable`/`NSTextBlock` is AppKit's own answer and is TextKit 1. The
/// editor is TextKit 2 on purpose — see `MarkdownStyleRenderer.viewportWindow`,
/// which avoids even READING `layoutManager` because that silently downgrades
/// the view.
///
/// So the columns are aligned by PADDING: each cell's trailing `|` — already
/// collapsed to nothing by the marker machinery — is given a `.kern` equal to
/// the space the cell needs to reach its column's width. The text is untouched,
/// no character is added or removed, and the alignment is exact rather than
/// approximate because the editor's base font is MONOSPACED, so a column's
/// width in characters is its width on screen.
///
/// ## Why it runs after collapse
///
/// `MarkdownStyleRenderer.collapse` writes `.kern = 0` over every hidden
/// marker. Padding applied before it would be wiped; padding applied after it
/// lands on top, which is also the only point at which the reveal state — and
/// therefore whether a row is showing its source at all — is known.
@MainActor
enum MarkdownTableStyling {

    /// Aligns every table in `spans` that is not currently revealed.
    ///
    /// - Parameter revealed: the source range whose syntax is shown. A row
    ///   inside it keeps its real `|` characters at full width, so padding it
    ///   would push the columns apart by the width of the pipes it can now see.
    ///   Obsidian does the same thing — the row you are editing goes back to
    ///   source — so this is the behaviour being matched, not a limitation.
    static func align(_ spans: [StyleSpan], revealed: Range<Int>?,
                      in storage: NSTextStorage) {
        let text = storage.string as NSString
        let space = (" " as NSString).size(
            withAttributes: [.font: MarkdownStyleRenderer.baseFont]).width
        guard space > 0 else { return }

        for span in spans {
            guard case .table = span.kind,
                  let table = MarkdownTable.parse(range: span.range, in: text)
            else { continue }

            for row in table.rows {
                // A revealed row shows its pipes, so it must not be padded.
                if let revealed,
                   row.range.lowerBound < revealed.upperBound,
                   revealed.lowerBound < row.range.upperBound { continue }

                for (column, cell) in row.cells.enumerated()
                where column < table.columnWidths.count {
                    let padding = table.columnWidths[column] - cell.width
                    guard padding > 0 else { continue }

                    // Where the slack goes decides how the column reads. Left
                    // puts it all after the cell, right all before it, centre
                    // splits it — with the ODD unit going after, so a column
                    // that cannot centre exactly leans the same way every row
                    // rather than jittering between them.
                    let alignment = column < table.columnAlignments.count
                        ? table.columnAlignments[column] : .left
                    let before: Int
                    switch alignment {
                    case .left: before = 0
                    case .right: before = padding
                    case .center: before = padding / 2
                    }

                    // The pipes that OPEN and CLOSE this cell. Found by
                    // position rather than by index arithmetic, which would be
                    // off by one for a row without a leading `|` — both
                    // spellings are legal GFM and a vault contains both.
                    let closing = row.pipes.first { $0.lowerBound >= cell.range.upperBound }
                    let opening = row.pipes.last { $0.upperBound <= cell.range.lowerBound }

                    // A first cell in a row with no leading `|` has nothing to
                    // pad in front of, so it stays left-aligned. Falling back
                    // is right: the alternative is padding the END and shifting
                    // every later column, which misaligns the whole row to
                    // honour one cell's colon.
                    let leading = opening == nil ? 0 : before
                    let trailing = padding - leading

                    if leading > 0, let opening {
                        pad(opening, by: leading, space: space, in: storage)
                    }
                    if trailing > 0, let closing {
                        pad(closing, by: trailing, space: space, in: storage)
                    }
                }
            }
        }
    }

    /// Writes `columns` worth of space into a collapsed pipe.
    private static func pad(_ pipe: Range<Int>, by columns: Int, space: CGFloat,
                            in storage: NSTextStorage) {
        let range = NSRange(location: pipe.lowerBound, length: pipe.count)
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.kern, value: CGFloat(columns) * space, range: range)
    }
}
