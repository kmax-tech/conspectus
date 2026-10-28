import XCTest
@testable import ConspectusCore

final class PDFPageTests: XCTestCase {

    func testParsePageAndPath() {
        XCTAssertEqual(parsePDFPageMessage("3:/Users/max/a.pdf"),
                       PDFPageHover(page: 3, path: "/Users/max/a.pdf", term: nil))
    }

    func testParsePathContainingColon() {
        // Only the FIRST colon separates the page; later ones belong to the path.
        XCTAssertEqual(parsePDFPageMessage("12:/tmp/a:b.pdf"),
                       PDFPageHover(page: 12, path: "/tmp/a:b.pdf", term: nil))
    }

    func testParseWithTerm() {
        XCTAssertEqual(parsePDFPageMessage("3:/Users/max/a.pdf\trosen"),
                       PDFPageHover(page: 3, path: "/Users/max/a.pdf", term: "rosen"))
        // The term may itself contain colons and spaces; only the tab splits.
        XCTAssertEqual(parsePDFPageMessage("3:/a:b.pdf\tfoo: bar"),
                       PDFPageHover(page: 3, path: "/a:b.pdf", term: "foo: bar"))
    }

    func testParseEmptyTermIsNone() {
        XCTAssertEqual(parsePDFPageMessage("3:/a.pdf\t"),
                       PDFPageHover(page: 3, path: "/a.pdf", term: nil))
    }

    func testParseMalformedReturnsNil() {
        XCTAssertNil(parsePDFPageMessage(""))                  // no page, no path
        XCTAssertNil(parsePDFPageMessage("/Users/max/a.pdf"))  // a bare hover, not a page message
        XCTAssertNil(parsePDFPageMessage("0:/a.pdf"))          // pages are 1-based
        XCTAssertNil(parsePDFPageMessage("-1:/a.pdf"))
        XCTAssertNil(parsePDFPageMessage("x:/a.pdf"))          // not a number
        XCTAssertNil(parsePDFPageMessage("3:a.pdf"))           // relative path
        XCTAssertNil(parsePDFPageMessage("3:"))                // empty path
        XCTAssertNil(parsePDFPageMessage("3:\trosen"))         // term but no path
    }
}
