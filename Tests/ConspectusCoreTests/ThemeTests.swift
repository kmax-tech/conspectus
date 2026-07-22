import XCTest
@testable import ConspectusCore

/// Tests for hex color parsing and NSColor conversion (Theme.swift).
final class ThemeTests: XCTestCase {
    func testParseHexColorParsesValidLiteral() throws {
        XCTAssertEqual(try parseHexColor("1E1E2E"), 0x1E1E2E)
        XCTAssertEqual(try parseHexColor("ffffff"), 0xFFFFFF)   // lowercase is fine
        XCTAssertEqual(try parseHexColor("000000"), 0)
    }

    func testParseHexColorThrowsOnNonHexDigits() {
        XCTAssertThrowsError(try parseHexColor("GGGGGG")) { error in
            XCTAssertEqual(error as? ColorError, .invalidHex("GGGGGG"))
        }
    }

    func testParseHexColorThrowsOnWrongLength() {
        XCTAssertThrowsError(try parseHexColor("FFF"))      // 3-digit shorthand not supported
        XCTAssertThrowsError(try parseHexColor(""))
        XCTAssertThrowsError(try parseHexColor("11223344")) // 8 digits (alpha) not supported
    }

    func testNsColorMatchesChannels() {
        let c = nsColor("FF8000")
        XCTAssertEqual(c.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(c.greenComponent, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.blueComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(c.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testBuiltInPalettesAreValid() {
        // The Palette initializer validates every entry; constructing the
        // built-ins is the test that no literal has gone bad.
        XCTAssertEqual(mocha.ansi.count, 16)
        XCTAssertEqual(latte.ansi.count, 16)
        XCTAssertNoThrow(try parseHexColor(mocha.bg))
        XCTAssertNoThrow(try parseHexColor(latte.bg))
    }
}
