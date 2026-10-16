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

    // listingDate: today/yesterday by name, this year with time, else year;
    // always 15 characters.
    private let utc = TimeZone(identifier: "UTC")!
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testListingDateTodayByName() {
        XCTAssertEqual(listingDate(date("2026-10-16T08:05:00Z"), now: date("2026-10-16T14:00:00Z"),
                                   timeZone: utc), "today     08:05")
    }

    func testListingDateYesterdayByName() {
        XCTAssertEqual(listingDate(date("2026-10-15T23:59:00Z"), now: date("2026-10-16T00:01:00Z"),
                                   timeZone: utc), "yesterday 23:59")
    }

    func testListingDateSameYearShowsTime() {
        XCTAssertEqual(listingDate(date("2026-10-14T14:32:00Z"), now: date("2026-10-16T12:00:00Z"),
                                   timeZone: utc), "14.10.    14:32")
    }

    func testListingDateOlderYearShowsYear() {
        XCTAssertEqual(listingDate(date("2024-01-15T12:00:00Z"), now: date("2026-10-16T00:00:00Z"),
                                   timeZone: utc), "15.01.     2024")
    }

    func testListingDateFutureYearShowsYear() {
        // A clock-skewed file from next year must not pass for "this year".
        XCTAssertEqual(listingDate(date("2027-03-01T08:00:00Z"), now: date("2026-10-16T00:00:00Z"),
                                   timeZone: utc), "01.03.     2027")
    }

    func testListingDateDayBoundaryFollowsTimeZone() {
        // 2026-10-15 22:30 UTC is already the 16th in Berlin: "today" there.
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        XCTAssertEqual(listingDate(date("2026-10-15T22:30:00Z"), now: date("2026-10-16T10:00:00Z"),
                                   timeZone: berlin), "today     00:30")
    }

    func testListingDateYesterdayAcrossYearBoundary() {
        XCTAssertEqual(listingDate(date("2025-12-31T18:00:00Z"), now: date("2026-01-01T09:00:00Z"),
                                   timeZone: utc), "yesterday 18:00")
    }

    func testListingDateIsAlwaysFifteenWide() {
        let now = date("2026-10-16T12:00:00Z")
        for iso in ["2026-10-16T01:00:00Z", "2026-10-15T01:00:00Z",
                    "2026-02-03T01:00:00Z", "1999-12-31T01:00:00Z"] {
            XCTAssertEqual(listingDate(date(iso), now: now, timeZone: utc).count, 15, iso)
        }
    }

    func testReadableSizeMatchesYazi() {
        XCTAssertEqual(readableSize(0), "0B")
        XCTAssertEqual(readableSize(807), "807B")
        XCTAssertEqual(readableSize(1023), "1023B")
        XCTAssertEqual(readableSize(1024), "1K")
        XCTAssertEqual(readableSize(32 * 1024), "32K")
        XCTAssertEqual(readableSize(626_893), "612.2K")
        XCTAssertEqual(readableSize(2_936_013), "2.8M")
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

/// Tests for the off-main-thread folder loader (Listing.swift, loadFolder).
final class LoadFolderTests: XCTestCase {
    private var tmp: String = ""

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "conspectus-listing-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: tmp)
    }

    func testLoadsSortedDirsFirstWithBulkIsDirBits() throws {
        try "x".write(toFile: tmp + "/b.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: tmp + "/a.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: tmp + "/zdir", withIntermediateDirectories: true)
        let c = loadFolder(tmp, cap: 500)
        XCTAssertNil(c.error)
        XCTAssertEqual(c.omitted, 0)
        // Real entries carry disk dates; compare name + isDir only.
        XCTAssertEqual(c.entries.map(\.name), ["zdir", "a.txt", "b.txt"])
        XCTAssertEqual(c.entries.map(\.isDir), [true, false, false])
    }

    func testCarriesModificationDates() throws {
        let file = tmp + "/old.txt"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let stamp = Date(timeIntervalSince1970: 1_705_320_000)   // 2024-01-15 12:00 UTC
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file)
        let c = loadFolder(tmp, cap: 500)
        XCTAssertEqual(c.entries.first?.modified, stamp)
        XCTAssertEqual(c.entries.first?.size, 1)
    }

    func testDirectoriesHaveNoSize() throws {
        try FileManager.default.createDirectory(atPath: tmp + "/sub", withIntermediateDirectories: true)
        XCTAssertNil(loadFolder(tmp, cap: 500).entries.first?.size)
    }

    func testCapAppliesAfterSortSoDirsSurvive() throws {
        for i in 1...5 {
            try "x".write(toFile: tmp + "/file\(i).txt", atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: tmp + "/zz-dir", withIntermediateDirectories: true)
        let c = loadFolder(tmp, cap: 3)
        XCTAssertEqual(c.entries.first?.name, "zz-dir")
        XCTAssertEqual(c.entries.count, 3)
        XCTAssertEqual(c.omitted, 3)
    }

    func testUnreadableFolderReturnsErrorNotEmpty() {
        let c = loadFolder(tmp + "/does-not-exist", cap: 500)
        XCTAssertNotNil(c.error, "a vanished folder must be reported, not shown as empty")
        XCTAssertEqual(c.entries, [])
    }

    func testEmptyFolderIsEmptyWithoutError() {
        let c = loadFolder(tmp, cap: 500)
        XCTAssertNil(c.error)
        XCTAssertEqual(c.entries, [])
        XCTAssertEqual(c.omitted, 0)
    }
}
