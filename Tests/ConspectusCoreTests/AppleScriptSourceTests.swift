import XCTest
@testable import ConspectusCore

final class AppleScriptSourceTests: XCTestCase {

    func testLiteralPlain() {
        XCTAssertEqual(appleScriptLiteral("/Users/max/a.txt"), "\"/Users/max/a.txt\"")
    }

    func testLiteralEscapesQuoteAndBackslash() {
        XCTAssertEqual(appleScriptLiteral(#"say "hi" \ bye"#), #""say \"hi\" \\ bye""#)
    }

    func testAlfredScriptSinglePath() {
        XCTAssertEqual(alfredActionsScript(paths: ["/a/b.pdf"]),
                       #"tell application id "com.runningwithcrayons.Alfred" to action {"/a/b.pdf"} as type "file""#)
    }

    func testAlfredScriptSeveralPathsKeepOrder() {
        XCTAssertEqual(alfredActionsScript(paths: ["/a", "/b c", "/d"]),
                       #"tell application id "com.runningwithcrayons.Alfred" to action {"/a", "/b c", "/d"} as type "file""#)
    }

    func testGetInfoScriptQuotesPath() {
        let s = finderGetInfoScript(path: #"/x/it's "odd".txt"#)
        XCTAssertTrue(s.contains(#"POSIX file "/x/it's \"odd\".txt" as alias"#), s)
        XCTAssertTrue(s.hasPrefix("tell application \"Finder\""))
    }
}
