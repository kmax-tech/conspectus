import XCTest
@testable import ConspectusCore

final class YankStateTests: XCTestCase {

    // MARK: parseYankMessage

    func testParseCopySingle() {
        XCTAssertEqual(parseYankMessage("copy:/Users/max/a.txt"),
                       YankState(isCut: false, paths: ["/Users/max/a.txt"]))
    }

    func testParseCutMultiple() {
        XCTAssertEqual(parseYankMessage("cut:/a/b\t/c/d\t/e"),
                       YankState(isCut: true, paths: ["/a/b", "/c/d", "/e"]))
    }

    func testParseClearedBuffer() {
        // Unyank (Y/X) and paste-after-cut publish an empty list.
        XCTAssertEqual(parseYankMessage("copy:"), YankState(isCut: false, paths: []))
        XCTAssertEqual(parseYankMessage("cut:"), YankState(isCut: true, paths: []))
    }

    func testParsePathContainingColon() {
        // Only the FIRST colon separates the mode; later ones belong to the path.
        XCTAssertEqual(parseYankMessage("copy:/tmp/a:b.txt"),
                       YankState(isCut: false, paths: ["/tmp/a:b.txt"]))
    }

    func testParseMalformedReturnsNil() {
        XCTAssertNil(parseYankMessage(""))               // no colon at all
        XCTAssertNil(parseYankMessage("yank:/a"))        // unknown mode
        XCTAssertNil(parseYankMessage("/a\t/b"))         // paths without a mode
    }

    // MARK: parseSelectedPaths

    func testParseSelectedMultiple() {
        XCTAssertEqual(parseSelectedPaths("/a/b.txt\t/c/d\t/e f/g.md"),
                       ["/a/b.txt", "/c/d", "/e f/g.md"])
    }

    func testParseSelectedEmpty() {
        XCTAssertEqual(parseSelectedPaths(""), [])
    }

    // MARK: yankHintSummary

    func testSummarySingleCopy() {
        XCTAssertEqual(yankHintSummary(YankState(isCut: false, paths: ["/Users/max/a.txt"])),
                       "1 copied · a.txt")
    }

    func testSummaryMultipleCut() {
        XCTAssertEqual(yankHintSummary(YankState(isCut: true, paths: ["/x/one.md", "/x/two.md", "/y/three"])),
                       "3 cut · one.md +2")
    }

    func testSummaryDirectoryUsesLastSegment() {
        XCTAssertEqual(yankHintSummary(YankState(isCut: false, paths: ["/Users/max/projects"])),
                       "1 copied · projects")
    }

    func testSummaryRootFallsBackToPath() {
        // "/" has no segments — the name falls back to the raw path.
        XCTAssertEqual(yankHintSummary(YankState(isCut: false, paths: ["/"])),
                       "1 copied · /")
    }

    func testSummaryEmptyBufferIsNil() {
        XCTAssertNil(yankHintSummary(YankState(isCut: false, paths: [])))
    }
}
