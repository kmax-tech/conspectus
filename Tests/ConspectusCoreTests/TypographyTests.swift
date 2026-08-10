import XCTest
@testable import ConspectusCore

final class TypographyTests: XCTestCase {
    private func de(_ s: String, previous: Character? = nil) -> String {
        SmartPunctuation.apply(s, style: .german, previous: previous)
    }
    private func en(_ s: String, previous: Character? = nil) -> String {
        SmartPunctuation.apply(s, style: .english, previous: previous)
    }

    func testEllipsisAndDashes() {
        XCTAssertEqual(de("und so weiter..."), "und so weiter…")
        XCTAssertEqual(de("Satz -- Einschub -- Ende"), "Satz – Einschub – Ende")
        XCTAssertEqual(de("Satz --- Ende"), "Satz — Ende")
    }

    func testGermanQuotesOpenAndClose() {
        XCTAssertEqual(de("Er sagte \"Hallo\" laut."), "Er sagte \u{201E}Hallo\u{201C} laut.")
    }

    func testEnglishQuotesOpenAndClose() {
        XCTAssertEqual(en("He said \"Hello\" loudly."), "He said \u{201C}Hello\u{201D} loudly.")
    }

    func testQuoteAfterOpeningBracketOpens() {
        XCTAssertEqual(de("(\"Zitat\")"), "(\u{201E}Zitat\u{201C})")
    }

    /// The run may start with a closing quote — `**Wort**"` splits into two
    /// runs, so the direction comes from the previous character.
    func testQuoteDirectionUsesPreviousCharacterAcrossRuns() {
        XCTAssertEqual(de("\" ist gemeint", previous: "t"), "\u{201C} ist gemeint")
        XCTAssertEqual(de("\"Wort", previous: " "), "\u{201E}Wort")
    }

    func testApostropheOnlyBetweenLetters() {
        XCTAssertEqual(en("don't"), "don\u{2019}t")
        XCTAssertEqual(en("echo 'x'"), "echo 'x'")     // shell quoting stays literal
    }

    func testDigitHyphensAreLeftAlone() {
        XCTAssertEqual(de("2026-08-10 und 1990-1995"), "2026-08-10 und 1990-1995")
    }

    func testStyleFromLanguageIdentifier() {
        XCTAssertEqual(SmartPunctuation.style(forLanguage: "de"), .german)
        XCTAssertEqual(SmartPunctuation.style(forLanguage: "de-DE"), .german)
        XCTAssertEqual(SmartPunctuation.style(forLanguage: "en"), .english)
        XCTAssertEqual(SmartPunctuation.style(forLanguage: nil), .english)
    }

    func testEmptyRunKeepsPrevious() {
        XCTAssertEqual(de(""), "")
    }
}
