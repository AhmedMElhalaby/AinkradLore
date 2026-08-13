import Foundation

/// The word under a UTF-16 offset, or nil when the offset is not in one.
///
/// Pure and text-view-free: this decides which word the spelling suggestions
/// are FOR, and it is asserted directly rather than through a view host.
enum WordAtPoint {

    /// Letters, digits, apostrophes and hyphens count as word characters —
    /// "don't" and "well-known" are single words to a speller, and splitting
    /// them would ask for suggestions on fragments.
    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
            || scalar == "'" || scalar == "\u{2019}" || scalar == "-"
    }

    static func range(in text: String, atUTF16 offset: Int) -> NSRange? {
        let ns = text as NSString
        // Clamped rather than trapped: an offset past the end is a legitimate
        // click on the trailing edge of the document, not a programming error.
        guard offset >= 0, offset <= ns.length, ns.length > 0 else { return nil }

        // An offset at a word's START belongs to that word (the character AT
        // it is a word character — no fallback needed). The ONE fallback is
        // the very END of the document: an offset there has no character of
        // its own to test, so it falls back to the one before it, letting a
        // click right after the last word on the page still hit that word.
        // Anywhere else, an offset sitting in whitespace or punctuation is
        // simply not in a word — it does NOT fall back to the word that ends
        // there, or "the quikc" at offset 3 (the space right after "the")
        // would wrongly resolve to "the".
        var probe = offset
        if probe == ns.length {
            guard probe > 0, isWordCharacter(ns.character(at: probe - 1)) else { return nil }
            probe -= 1
        } else if !isWordCharacter(ns.character(at: probe)) {
            return nil
        }

        var start = probe
        while start > 0, isWordCharacter(ns.character(at: start - 1)) { start -= 1 }
        var end = probe
        while end < ns.length, isWordCharacter(ns.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}
