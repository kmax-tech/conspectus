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

    func testCapEntriesUnderLimitKeepsAll() {
        let entries = [DirEntry(name: "a", isDir: true), DirEntry(name: "b", isDir: false)]
        let r = capEntries(entries, limit: 500)
        XCTAssertEqual(r.shown, entries)
        XCTAssertEqual(r.omitted, 0)
    }

    func testCapEntriesOverLimitCutsAndCounts() {
        // Sorted first (dirs-first), then capped — directories survive the cap
        // even when the folder has more entries than the limit.
        let files = (1...600).map { DirEntry(name: "file\($0).txt", isDir: false) }
        let dirs = [DirEntry(name: "zzz-last-dir", isDir: true)]
        let r = capEntries(sortEntries(files + dirs), limit: 500)
        XCTAssertEqual(r.shown.count, 500)
        XCTAssertEqual(r.omitted, 101)
        XCTAssertEqual(r.shown.first, DirEntry(name: "zzz-last-dir", isDir: true))
        XCTAssertEqual(r.shown[1].name, "file1.txt")   // natural order after the dirs
    }

    func testCapEntriesExactlyAtLimitOmitsNothing() {
        let entries = (1...3).map { DirEntry(name: "f\($0)", isDir: false) }
        let r = capEntries(entries, limit: 3)
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
