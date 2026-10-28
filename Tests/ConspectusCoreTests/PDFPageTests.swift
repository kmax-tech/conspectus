import XCTest
@testable import ConspectusCore

final class PDFPageTests: XCTestCase {

    func testParsePageAndPath() {
        XCTAssertEqual(parsePDFPageMessage("3:/Users/max/a.pdf"),
                       PDFPageHover(page: 3, path: "/Users/max/a.pdf"))
    }

    func testParsePathContainingColon() {
        // Only the FIRST colon separates the page; later ones belong to the path.
        XCTAssertEqual(parsePDFPageMessage("12:/tmp/a:b.pdf"),
                       PDFPageHover(page: 12, path: "/tmp/a:b.pdf"))
    }

    func testParseMalformedReturnsNil() {
        XCTAssertNil(parsePDFPageMessage(""))                  // no page, no path
        XCTAssertNil(parsePDFPageMessage("/Users/max/a.pdf"))  // a bare hover, not a page message
        XCTAssertNil(parsePDFPageMessage("0:/a.pdf"))          // pages are 1-based
        XCTAssertNil(parsePDFPageMessage("-1:/a.pdf"))
        XCTAssertNil(parsePDFPageMessage("x:/a.pdf"))          // not a number
        XCTAssertNil(parsePDFPageMessage("3:a.pdf"))           // relative path
        XCTAssertNil(parsePDFPageMessage("3:"))                // empty path
    }
}
