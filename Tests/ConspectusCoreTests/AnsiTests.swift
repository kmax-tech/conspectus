import XCTest
@testable import ConspectusCore

final class AnsiTests: XCTestCase {
    func testPlainTextIsOneDefaultRun() {
        let runs = parseANSI("hello world")
        XCTAssertEqual(runs, [AnsiRun(text: "hello world", fg: nil, bold: false, italic: false, underline: false)])
    }

    func testTruecolorForegroundAndReset() {
        // exactly what bat emits: fg truecolor, then reset
        let runs = parseANSI("\u{1B}[38;2;102;217;239mlet\u{1B}[0m x")
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0], AnsiRun(text: "let", fg: RGB(102, 217, 239), bold: false, italic: false, underline: false))
        XCTAssertEqual(runs[1].text, " x")
        XCTAssertNil(runs[1].fg)   // reset → default fg
    }

    func testStylesBoldItalicUnderline() {
        let runs = parseANSI("\u{1B}[1;3;4mX\u{1B}[0mY")
        XCTAssertEqual(runs[0], AnsiRun(text: "X", fg: nil, bold: true, italic: true, underline: true))
        XCTAssertEqual(runs[1], AnsiRun(text: "Y", fg: nil, bold: false, italic: false, underline: false))
    }

    func test256AndBasicColors() {
        // 38;5;196 is a bright red in the cube; 31 is ansi red
        let r256 = parseANSI("\u{1B}[38;5;196mA\u{1B}[0m")[0].fg
        XCTAssertEqual(r256, RGB(255, 0, 0))
        let r16 = parseANSI("\u{1B}[31mB\u{1B}[0m")[0].fg
        XCTAssertEqual(r16, RGB(205, 0, 0))
    }

    func testNewlinesPreserved() {
        let runs = parseANSI("a\nb\nc")
        XCTAssertEqual(runs.map(\.text).joined(), "a\nb\nc")
    }

    func testBackgroundColor() {
        // truecolor bg (glow code blocks) then reset
        let runs = parseANSI("\u{1B}[48;2;40;40;40mcode\u{1B}[0mplain")
        XCTAssertEqual(runs[0].bg, RGB(40, 40, 40))
        XCTAssertNil(runs[0].fg)
        XCTAssertNil(runs[1].bg)   // reset clears bg too
    }

    func testEmptyParamsAreReset() {
        // glow emits `\e[;;1m` (bold with empty leading params) and `\e[;3m`
        let bold = parseANSI("\u{1B}[;;1mH\u{1B}[0m")[0]
        XCTAssertTrue(bold.bold)
        let italic = parseANSI("\u{1B}[;3mI\u{1B}[0m")[0]
        XCTAssertTrue(italic.italic)
    }
}
