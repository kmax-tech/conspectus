import Foundation

/// Typographic punctuation for rendered prose. swift-markdown hands back the
/// characters the author typed, so quotes stay straight, `...` stays three dots
/// and `--` stays two hyphens. Turning those into the real glyphs is the most
/// visible quality gain per line of code in the markdown preview.
///
/// Applied to plain-text runs only — never to code spans, link destinations or
/// URLs, which is why this is a function over one text run instead of a regex
/// over the whole document (the usual way to mangle `--flag` inside code).
///
/// Whether a `"` opens or closes depends on what precedes it, and that may sit
/// in an earlier run (`**Wort**"` → the quote closes). Callers therefore thread
/// the last emitted character through `previous`.
public enum SmartPunctuation {
    /// Quote glyphs differ by language: German „…“ vs. English “…”.
    public enum Style {
        case german
        case english

        var openDouble: Character { self == .german ? "\u{201E}" : "\u{201C}" }   // „ / “
        var closeDouble: Character { self == .german ? "\u{201C}" : "\u{201D}" }  // “ / ”
    }

    /// Pick the quote style from a BCP-47 language identifier (as detected for
    /// the document). Anything that is not German gets the English quotes —
    /// they are the sane default for the Latin-script languages in reach here.
    public static func style(forLanguage id: String?) -> Style {
        (id?.lowercased().hasPrefix("de") ?? false) ? .german : .english
    }

    /// Convert one plain-text run. `previous` is the last character emitted
    /// before this run (nil at the start of a block).
    ///
    /// Deliberately conservative — only transformations that cannot misfire on
    /// technical prose:
    /// - `...` → `…`, `--` → `–`, `---` → `—`
    /// - `"` → paired quotes, direction from the preceding character
    /// - `'` between letters → `’` (apostrophe); standalone `'` is left alone,
    ///   because in these notes it is more often a quote in a shell snippet
    ///   than an English single quotation mark.
    ///
    /// Not converted: hyphens between digits. `2026-08-10` is a date and
    /// `1990-1995` a range; no rule tells them apart, so both stay as typed.
    public static func apply(_ s: String, style: Style, previous: Character? = nil) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var prev = previous
        var i = s.startIndex

        func emit(_ c: Character, advance: Int) {
            out.append(c)
            prev = c
            i = s.index(i, offsetBy: advance)
        }

        while i < s.endIndex {
            let rest = s[i...]
            if rest.hasPrefix("...") { emit("\u{2026}", advance: 3); continue }   // …
            if rest.hasPrefix("---") { emit("\u{2014}", advance: 3); continue }   // —
            if rest.hasPrefix("--")  { emit("\u{2013}", advance: 2); continue }   // –

            let c = s[i]
            if c == "\"" {
                emit(opensQuote(after: prev) ? style.openDouble : style.closeDouble, advance: 1)
                continue
            }
            if c == "'", let p = prev, p.isLetter, isLetter(s, after: i) {
                emit("\u{2019}", advance: 1)                                       // ’
                continue
            }
            emit(c, advance: 1)
        }
        return out
    }

    /// A quote opens at the start of a run and after whitespace, an opening
    /// bracket or a dash; everywhere else (after a letter, digit, or closing
    /// punctuation) it closes.
    private static func opensQuote(after prev: Character?) -> Bool {
        guard let p = prev else { return true }
        if p.isWhitespace { return true }
        return "([{<\u{2013}\u{2014}-\u{201E}\u{201C}\u{2018}«".contains(p)
    }

    /// Is the character right after `i` a letter? (Apostrophe test: `don't`.)
    private static func isLetter(_ s: String, after i: String.Index) -> Bool {
        let n = s.index(after: i)
        return n < s.endIndex && s[n].isLetter
    }
}
