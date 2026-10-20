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

    // sortEntries with yazi's other preferences (ListingSort).
    private func stamp(_ day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400) }
    private var mixed: [DirEntry] {[
        DirEntry(name: "b.txt", isDir: false, modified: stamp(2), size: 300, created: stamp(1)),
        DirEntry(name: "a.md", isDir: false, modified: stamp(3), size: 100, created: stamp(3)),
        DirEntry(name: "dir", isDir: true, modified: stamp(1), size: nil, created: stamp(2)),
        DirEntry(name: "c.txt", isDir: false, modified: stamp(2), size: 200, created: stamp(4)),
    ]}

    func testSortEntriesMtimeReverseMixedIsYaziTimeline() {
        // `, t`: newest first, dirs mixed in; equal mtimes break by name, reversed.
        let sort = ListingSort(by: .mtime, reverse: true, dirFirst: false)
        XCTAssertEqual(sortEntries(mixed, sort).map(\.name), ["a.md", "c.txt", "b.txt", "dir"])
    }

    func testSortEntriesMtimeKeepsDirsFirst() {
        let sort = ListingSort(by: .mtime, reverse: false, dirFirst: true)
        XCTAssertEqual(sortEntries(mixed, sort).map(\.name), ["dir", "b.txt", "c.txt", "a.md"])
    }

    func testSortEntriesSizeTreatsDirAsZero() {
        let sort = ListingSort(by: .size, reverse: false, dirFirst: false)
        XCTAssertEqual(sortEntries(mixed, sort).map(\.name), ["dir", "a.md", "c.txt", "b.txt"])
    }

    func testSortEntriesBtime() {
        let sort = ListingSort(by: .btime, reverse: false, dirFirst: false)
        XCTAssertEqual(sortEntries(mixed, sort).map(\.name), ["b.txt", "dir", "a.md", "c.txt"])
    }

    func testSortEntriesExtensionDirsHaveNone() {
        let sort = ListingSort(by: .extension, reverse: false, dirFirst: false)
        XCTAssertEqual(sortEntries(mixed, sort).map(\.name), ["dir", "a.md", "b.txt", "c.txt"])
    }

    func testSortEntriesRandomAndNoneFallBackToNatural() {
        for by in [ListingSort.By.random, .none] {
            let sort = ListingSort(by: by, reverse: false, dirFirst: true)
            XCTAssertEqual(sortEntries(mixed, sort), sortEntries(mixed), "\(by)")
        }
    }

    func testParseListingSortValid() {
        XCTAssertEqual(parseListingSort("mtime:true:false"),
                       ListingSort(by: .mtime, reverse: true, dirFirst: false))
        XCTAssertEqual(parseListingSort("natural:false:true"), ListingSort.default)
    }

    func testParseListingSortRejectsGarbage() {
        XCTAssertNil(parseListingSort(""))
        XCTAssertNil(parseListingSort("mtime:true"))
        XCTAssertNil(parseListingSort("bogus:true:true"))
        XCTAssertNil(parseListingSort("mtime:yes:no"))
        XCTAssertNil(parseListingSort("mtime:true:false:extra"))
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
    // always 12 characters.
    private let utc = TimeZone(identifier: "UTC")!
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testListingDateTodayByName() {
        XCTAssertEqual(listingDate(date("2026-10-16T08:05:00Z"), now: date("2026-10-16T14:00:00Z"),
                                   timeZone: utc), "today  08:05")
    }

    func testListingDateYesterdayByName() {
        XCTAssertEqual(listingDate(date("2026-10-15T23:59:00Z"), now: date("2026-10-16T00:01:00Z"),
                                   timeZone: utc), "yester 23:59")
    }

    func testListingDateSameYearShowsTime() {
        XCTAssertEqual(listingDate(date("2026-10-14T14:32:00Z"), now: date("2026-10-16T12:00:00Z"),
                                   timeZone: utc), "14.10. 14:32")
    }

    func testListingDateOlderYearShowsYear() {
        XCTAssertEqual(listingDate(date("2024-01-15T12:00:00Z"), now: date("2026-10-16T00:00:00Z"),
                                   timeZone: utc), "15.01.  2024")
    }

    func testListingDateFutureYearShowsYear() {
        // A clock-skewed file from next year must not pass for "this year".
        XCTAssertEqual(listingDate(date("2027-03-01T08:00:00Z"), now: date("2026-10-16T00:00:00Z"),
                                   timeZone: utc), "01.03.  2027")
    }

    func testListingDateDayBoundaryFollowsTimeZone() {
        // 2026-10-15 22:30 UTC is already the 16th in Berlin: "today" there.
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        XCTAssertEqual(listingDate(date("2026-10-15T22:30:00Z"), now: date("2026-10-16T10:00:00Z"),
                                   timeZone: berlin), "today  00:30")
    }

    func testListingDateYesterdayAcrossYearBoundary() {
        XCTAssertEqual(listingDate(date("2025-12-31T18:00:00Z"), now: date("2026-01-01T09:00:00Z"),
                                   timeZone: utc), "yester 18:00")
    }

    func testListingDateIsAlwaysTwelveWide() {
        let now = date("2026-10-16T12:00:00Z")
        for iso in ["2026-10-16T01:00:00Z", "2026-10-15T01:00:00Z",
                    "2026-02-03T01:00:00Z", "1999-12-31T01:00:00Z"] {
            XCTAssertEqual(listingDate(date(iso), now: now, timeZone: utc).count, 12, iso)
        }
    }

    func testTruncateNameLeavesFittingNamesAlone() {
        XCTAssertEqual(truncateName("notes.md", isDir: false, max: 40), "notes.md")
        XCTAssertEqual(truncateName("art", isDir: true, max: 40), "art/")
        // Exactly the column width, "/" included, still fits.
        XCTAssertEqual(truncateName(String(repeating: "a", count: 39), isDir: true, max: 40),
                       String(repeating: "a", count: 39) + "/")
    }

    func testTruncateNameKeepsExtensionLikeYazi() {
        let long = "lenz09-soziologie-der-zweierbeziehung-eine-einfhrung-ch01.pdf"
        let cut = truncateName(long, isDir: false, max: 40)
        XCTAssertEqual(cut, "lenz09-soziologie-der-zweierbeziehu….pdf")
        XCTAssertEqual(cut.count, 40)
        // archive.tar.gz → extension "gz", like Path::extension.
        XCTAssertEqual(truncateName(String(repeating: "x", count: 50) + ".tar.gz", isDir: false, max: 20),
                       String(repeating: "x", count: 16) + "….gz")
    }

    func testTruncateNameWithoutExtensionEndsInEllipsis() {
        XCTAssertEqual(truncateName(String(repeating: "n", count: 50), isDir: false, max: 10),
                       String(repeating: "n", count: 9) + "…")
        // A leading dot is not an extension.
        XCTAssertEqual(truncateName(".very-long-hidden-rc-file-name", isDir: false, max: 10),
                       ".very-lon…")
        // Directories keep their "/" after the ellipsis.
        XCTAssertEqual(truncateName(String(repeating: "d", count: 50), isDir: true, max: 10),
                       String(repeating: "d", count: 8) + "…/")
    }

    func testTruncateNameNeverExceedsWidth() {
        for max in 2...12 {
            for name in ["a.pdf", "abcdefgh.markdown", ".hidden", "x.", String(repeating: "q", count: 30)] {
                XCTAssertLessThanOrEqual(truncateName(name, isDir: false, max: max).count, max,
                                         "\(name) at \(max)")
                XCTAssertLessThanOrEqual(truncateName(name, isDir: true, max: max).count, max,
                                         "\(name)/ at \(max)")
            }
        }
        // Extension wider than the column falls back to a bare ellipsis.
        XCTAssertEqual(truncateName("abcdefgh.markdown", isDir: false, max: 8), "abcdefg…")
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
        XCTAssertNotNil(c.entries.first?.created)
    }

    func testLoadFolderHonoursSort() throws {
        try "x".write(toFile: tmp + "/a.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: tmp + "/zdir", withIntermediateDirectories: true)
        let mixed = ListingSort(by: .natural, reverse: false, dirFirst: false)
        XCTAssertEqual(loadFolder(tmp, cap: 500, sort: mixed).entries.map(\.name), ["a.txt", "zdir"])
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
