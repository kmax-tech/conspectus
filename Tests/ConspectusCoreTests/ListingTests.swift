import XCTest
@testable import ConspectusCore

/// Tests for listing order and the extension -> icon mapping (Listing.swift).
final class ListingTests: XCTestCase {
    func testSortEntriesPutsDirectoriesFirst() {
        let sorted = sortEntries([
            DirEntry(name: "zzz.txt", isDir: false),
            DirEntry(name: "aaa.txt", isDir: false),
            DirEntry(name: "zdir", isDir: true),
            DirEntry(name: "adir", isDir: true),
        ])
        XCTAssertEqual(sorted.map(\.name), ["adir", "zdir", "aaa.txt", "zzz.txt"])
    }

    func testSortEntriesUsesNaturalNumberOrder() {
        let sorted = sortEntries([
            DirEntry(name: "file10.txt", isDir: false),
            DirEntry(name: "file2.txt", isDir: false),
        ])
        XCTAssertEqual(sorted.map(\.name), ["file2.txt", "file10.txt"])
    }

    func testSortEntriesEmptyInput() {
        XCTAssertEqual(sortEntries([]), [])
    }

    func testCapNamesUnderLimitKeepsAllSorted() {
        let r = capNames(["b.txt", "a.txt"], limit: 500)
        XCTAssertEqual(r.shown, ["a.txt", "b.txt"])
        XCTAssertEqual(r.omitted, 0)
    }

    func testCapNamesOverLimitCutsAndCounts() {
        let names = (1...600).map { "file\($0).txt" }.shuffled()
        let r = capNames(names, limit: 500)
        XCTAssertEqual(r.shown.count, 500)
        XCTAssertEqual(r.omitted, 100)
        XCTAssertEqual(r.shown.first, "file1.txt")     // natural order survives the cap
        XCTAssertEqual(r.shown.last, "file500.txt")
    }

    func testCapNamesExactlyAtLimitOmitsNothing() {
        let r = capNames(["a", "b", "c"], limit: 3)
        XCTAssertEqual(r.shown.count, 3)
        XCTAssertEqual(r.omitted, 0)
    }

    func testFileIconKnownExtensions() {
        XCTAssertEqual(fileIcon("paper.pdf", mocha).glyph, "\u{f1c1}")
        XCTAssertEqual(fileIcon("photo.jpg", mocha).glyph, "\u{f1c5}")
        XCTAssertEqual(fileIcon("main.swift", mocha).glyph, "\u{f1c9}")
        XCTAssertEqual(fileIcon("notes.md", mocha).glyph, "\u{f15c}")
    }

    func testFileIconIsCaseInsensitive() {
        XCTAssertEqual(fileIcon("SCAN.PDF", mocha).glyph, fileIcon("scan.pdf", mocha).glyph)
    }

    func testFileIconUnknownExtensionGetsGenericGlyph() {
        XCTAssertEqual(fileIcon("mystery.xyz", mocha).glyph, "\u{f15b}")
        XCTAssertEqual(fileIcon("no-extension", mocha).glyph, "\u{f15b}")
    }
}
