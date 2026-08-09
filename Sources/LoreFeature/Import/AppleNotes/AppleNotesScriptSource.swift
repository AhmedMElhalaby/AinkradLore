import Foundation

public protocol ScriptRunner: Sendable {
    func run(_ source: String) throws -> String
}

/// Runs AppleScript through `NSAppleScript`.
///
/// MUST BE CALLED ON THE MAIN ACTOR. `NSAppleScript` is not thread-safe, and
/// executing it off the main thread requires a run loop of its own.
///
/// The requirement is enforced by `assumeIsolated` (which traps rather than
/// silently misbehaving) instead of by marking the type `@MainActor`, because
/// the protocol it conforms to is not isolated — an isolated conformance would
/// make `ScriptRunner` unusable as a plain injected dependency, which is the
/// one thing it exists to be. `AppleNotesScriptSource.scan` hops to the main
/// actor before every call.
public struct OSAScriptRunner: ScriptRunner {
    public init() {}

    public func run(_ source: String) throws -> String {
        try MainActor.assumeIsolated {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                throw ImportSourceError.sourceUnavailable("could not compile the script")
            }
            let result = script.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                // -1743 is "not authorised to send Apple events" — an
                // Automation TCC denial, which is a DIFFERENT grant from the
                // Full Disk Access the SQLite path needs. Either can be
                // blocked while the other works, so this must not be reported
                // as a generic failure: the sentence tells the user which of
                // the two switches to go and flip.
                if code == -1743 {
                    throw ImportSourceError.permissionDenied(
                        "Allow Ainkrad to control Notes in System Settings → "
                            + "Privacy & Security → Automation.")
                }
                throw ImportSourceError.sourceUnavailable(
                    error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed")
            }
            return result.stringValue ?? ""
        }
    }
}

/// The Apple Notes fallback: a supported, documented API that survives OS
/// updates, at the cost of being slow on large libraries and unable to see
/// locked notes or every attachment type.
///
/// It exists because the fast path reads an undocumented internal format that
/// Apple can change without notice. This one asks Notes.app itself.
///
/// The runner is injected so tests exercise the parser against canned output
/// WITHOUT driving Notes.app. A test must never launch Notes: it would depend
/// on the contents of the developer's own note library, prompt for an
/// Automation grant mid-suite, and fail differently on every machine.
public struct AppleNotesScriptSource: ImportSource {
    public static let identifier = "apple-notes"
    private let runner: ScriptRunner

    public init(runner: ScriptRunner = OSAScriptRunner()) { self.runner = runner }

    /// Emits six fields per note, one per line, records separated by a line
    /// holding only ASCII 30 (RECORD SEPARATOR) — a control character that
    /// cannot occur in a note title or body, unlike any printable delimiter.
    ///
    /// Dates are emitted as SECONDS SINCE THE UNIX EPOCH rather than
    /// `as string`. An AppleScript date string is formatted in the user's
    /// locale and calendar, so parsing it back would work on the developer's
    /// machine and fail on a machine set to a different region — the classic
    /// shape of a bug nobody can reproduce.
    ///
    /// The epoch is built by mutating a date rather than parsing a literal,
    /// because a `date "..."` literal is itself locale-dependent. Subtracting
    /// two dates yields elapsed seconds against LOCAL midnight, so `time to
    /// GMT` (the zone offset in seconds) is removed to land on true UTC.
    static let script = """
    set epoch to current date
    set year of epoch to 1970
    set month of epoch to January
    set day of epoch to 1
    set time of epoch to 0
    set zone to (time to GMT)
    set out to ""
    tell application "Notes"
      repeat with n in notes
        set out to out & (id of n) & linefeed & (name of n) & linefeed & ¬
          (name of container of n) & linefeed & ¬
          (((creation date of n) - epoch - zone) as string) & linefeed & ¬
          (((modification date of n) - epoch - zone) as string) & linefeed & ¬
          (body of n) & linefeed & (ASCII character 30) & linefeed
      end repeat
    end tell
    return out
    """

    public func scan() async throws -> [ImportItem] {
        let runner = self.runner
        let output = try await MainActor.run { try runner.run(Self.script) }
        return Self.parse(output)
    }

    /// Records that are short of their six fields are DROPPED rather than
    /// padded. A truncated record means the script was interrupted partway
    /// through emitting it, and guessing at the missing fields would import a
    /// note with a fabricated title or date — which is worse than importing
    /// one note fewer from a run the user can simply repeat.
    static func parse(_ output: String) -> [ImportItem] {
        output.components(separatedBy: "\u{1E}").compactMap { record -> ImportItem? in
            var lines = record.components(separatedBy: "\n")
                .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            while let first = lines.first,
                  first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
            while let last = lines.last,
                  last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            guard lines.count >= 6 else { return nil }
            // The body is everything from field six on: an HTML body spans as
            // many lines as it likes, and rejoining them is the only way to
            // keep a multi-line note intact.
            let html = lines[5...].joined(separator: "\n")
            return ImportItem(
                sourceID: "\(identifier):\(lines[0])",
                title: lines[1],
                body: .html(html),
                attachments: [],
                folderPath: lines[2].isEmpty ? [] : [lines[2]],
                created: Self.date(lines[3]),
                modified: Self.date(lines[4]),
                fidelity: [],
                kind: .note)
        }
    }

    /// AppleScript renders a whole-number difference without a decimal point,
    /// but a locale using `,` as the decimal mark could still reach here — so
    /// an unparseable value becomes the epoch rather than crashing the run.
    /// A wrong date on an imported note is recoverable; losing the note is not.
    static func date(_ raw: String) -> Date {
        Date(timeIntervalSince1970: Double(raw.trimmingCharacters(in: .whitespaces)) ?? 0)
    }
}
