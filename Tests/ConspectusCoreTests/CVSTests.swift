import XCTest
@testable import ConspectusCore

/// Tests for CVS working-copy detection and the offline status (CVS.swift).
final class CVSTests: XCTestCase {
    /// Scratch area for the test; recreated per test, removed afterwards.
    private var tmp: String = ""

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "conspectus-cvs-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp + "/CVS", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: tmp)
    }

    private func markAsCheckout() throws {
        try ":ext:host:/cvsroot\n".write(toFile: tmp + "/CVS/Root", atomically: true, encoding: .utf8)
    }

    func testDirectoryWithRootMarkerIsItsOwnWorkingDir() throws {
        try markAsCheckout()
        XCTAssertEqual(cvsWorkingDir(for: tmp), tmp)
    }

    func testFileResolvesToItsParentCheckout() throws {
        try markAsCheckout()
        let file = tmp + "/paper.tex"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(cvsWorkingDir(for: file), tmp)
    }

    func testCVSDirWithoutRootIsNotACheckout() {
        XCTAssertNil(cvsWorkingDir(for: tmp), "a bare CVS/ folder without Root is not a checkout")
    }

    func testMissingPathIsNotACheckout() {
        XCTAssertNil(cvsWorkingDir(for: tmp + "/nope/deeper"))
    }

    // MARK: Entries parsing

    func testParsesFileAndDirLinesAndSkipsLoneD() {
        let f = parseCVSEntries("""
        /a.txt/1.4/Sun Feb 18 19:33:43 2024//
        /pic.png/1.1/Mon Mar  4 09:05:00 2024/-kb/
        D/sub////
        D
        """)
        XCTAssertEqual(f.entries["a.txt"], CVSEntry(name: "a.txt", isDir: false, revision: "1.4",
                                                    timestamp: "Sun Feb 18 19:33:43 2024"))
        XCTAssertEqual(f.entries["pic.png"]?.timestamp, "Mon Mar  4 09:05:00 2024")
        XCTAssertEqual(f.entries["sub"], CVSEntry(name: "sub", isDir: true))
        XCTAssertEqual(f.entries.count, 3)
        XCTAssertEqual(f.malformed, [])
    }

    func testEntriesLogAddsAndRemoves() {
        let f = parseCVSEntries("/a.txt/1.1/x//\n/b.txt/1.1/x//\n",
                                log: "A /c.txt/0/dummy timestamp//\nR /a.txt/1.1/x//\n")
        XCTAssertEqual(Set(f.entries.keys), ["b.txt", "c.txt"])
        XCTAssertEqual(f.entries["c.txt"]?.revision, "0")
    }

    func testMalformedLinesAreReportedNotGuessed() {
        let f = parseCVSEntries("garbage\n/a.txt/1.1/x//\n", log: "X /b.txt/1.1/x//\n")
        XCTAssertEqual(f.malformed, ["garbage", "X /b.txt/1.1/x//"])
        XCTAssertEqual(Set(f.entries.keys), ["a.txt"])
    }

    // MARK: Timestamp and per-file status

    /// 2024-03-04 09:05:00 UTC.
    private let march4 = Date(timeIntervalSince1970: 1_709_543_100)

    func testTimestampIsAsctimeUTCWithSpacePaddedDay() {
        XCTAssertEqual(cvsTimestamp(march4), "Mon Mar  4 09:05:00 2024")
        XCTAssertEqual(cvsTimestamp(march4.addingTimeInterval(0.9)), "Mon Mar  4 09:05:00 2024",
                       "sub-second mtime parts are dropped, as CVS stores whole seconds")
    }

    private func entry(rev: String = "1.1", ts: String) -> CVSEntry {
        CVSEntry(name: "f", isDir: false, revision: rev, timestamp: ts)
    }

    func testFileStatusFromRevisionAndTimestamp() {
        let ts = "Mon Mar  4 09:05:00 2024"
        let never: () -> Bool = { XCTFail("markers read without a conflicted merge"); return false }
        XCTAssertEqual(cvsFileStatus(entry(ts: ts), mtime: march4, hasConflictMarkers: never), .clean)
        XCTAssertEqual(cvsFileStatus(entry(ts: ts), mtime: march4 + 1, hasConflictMarkers: never), .modified)
        XCTAssertEqual(cvsFileStatus(entry(ts: "Result of merge"), mtime: march4, hasConflictMarkers: never),
                       .modified)
        XCTAssertEqual(cvsFileStatus(entry(rev: "0", ts: "Initial f"), mtime: march4, hasConflictMarkers: never),
                       .added)
        XCTAssertEqual(cvsFileStatus(entry(rev: "-1.3", ts: ts), mtime: march4, hasConflictMarkers: never),
                       .removed)
    }

    func testConflictedMergeStaysConflictWhileMarkersRemain() {
        let e = entry(ts: "Result of merge+Mon Mar  4 09:05:00 2024")
        XCTAssertEqual(cvsFileStatus(e, mtime: march4, hasConflictMarkers: { false }), .conflict,
                       "untouched since the merge")
        XCTAssertEqual(cvsFileStatus(e, mtime: march4 + 60, hasConflictMarkers: { true }), .conflict)
        XCTAssertEqual(cvsFileStatus(e, mtime: march4 + 60, hasConflictMarkers: { false }), .modified)
    }

    func testConflictMarkerDetection() {
        XCTAssertTrue(containsConflictMarkers("a\n<<<<<<< f.txt\nx\n=======\ny\n>>>>>>> 1.2\n"))
        XCTAssertTrue(containsConflictMarkers("a\n=======\nb"))
        XCTAssertFalse(containsConflictMarkers("Title\n======= \n"), "setext underline with trailing space")
        XCTAssertFalse(containsConflictMarkers("a <<<<<<< b\n"), "only at line start")
    }

    // MARK: Ignore patterns

    func testIgnoreListOrderAndBangReset() {
        XCTAssertEqual(cvsIgnorePatterns(home: nil, env: nil, dir: nil), cvsDefaultIgnore)
        XCTAssertEqual(cvsIgnorePatterns(home: "*.log\n", env: "*.aux  *.bbl", dir: "out"),
                       cvsDefaultIgnore + ["*.log", "*.aux", "*.bbl", "out"])
        XCTAssertEqual(cvsIgnorePatterns(home: "*.log", env: nil, dir: "! *.pdf"), ["*.pdf"])
    }

    func testIgnoreMatchesGlobs() {
        XCTAssertTrue(cvsIgnored("x.o", patterns: cvsDefaultIgnore))
        XCTAssertTrue(cvsIgnored("._paper.tex", patterns: cvsDefaultIgnore))
        XCTAssertTrue(cvsIgnored("CVS", patterns: cvsDefaultIgnore))
        XCTAssertFalse(cvsIgnored("paper.tex", patterns: cvsDefaultIgnore))
    }

    // MARK: Directory statuses

    func testStatusesClassifyEveryEntryOnDisk() {
        let ts = "Mon Mar  4 09:05:00 2024"
        let entries = parseCVSEntries("/a.tex/1.1/\(ts)//\n/b.tex/1.1/\(ts)//\n/gone.tex/1.1/\(ts)//\nD/sub////\n")
        let disk = [DirEntry(name: "a.tex", isDir: false, modified: march4),
                    DirEntry(name: "b.tex", isDir: false, modified: march4 + 5),
                    DirEntry(name: "sub", isDir: true),
                    DirEntry(name: "old", isDir: true),
                    DirEntry(name: "new", isDir: true),
                    DirEntry(name: "notes.md", isDir: false, modified: march4),
                    DirEntry(name: "x.o", isDir: false, modified: march4)]
        let st = cvsStatuses(entries: entries, onDisk: disk, checkedOutSubdirs: ["old"],
                             ignore: cvsDefaultIgnore, hasConflictMarkers: { _ in false })
        XCTAssertEqual(st, ["a.tex": .clean, "b.tex": .modified, "sub": .clean, "old": .clean,
                            "new": .unknown, "notes.md": .unknown, "x.o": .ignored],
                       "gone.tex has no file, so nothing lists it")
    }

    func testReadStatusesNilOutsideACheckout() {
        XCTAssertNil(readCVSStatuses(in: tmp), "a CVS/ folder without Entries is no checkout")
    }

    func testReadStatusesFromDisk() throws {
        let file = tmp + "/a.tex"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: march4], ofItemAtPath: file)
        try "y".write(toFile: tmp + "/b.tex", atomically: true, encoding: .utf8)
        try "*.tex\n".write(toFile: tmp + "/.cvsignore", atomically: true, encoding: .utf8)
        try "/a.tex/1.1/Mon Mar  4 09:05:00 2024//\n/.cvsignore/1.1/x//\nbad\n"
            .write(toFile: tmp + "/CVS/Entries", atomically: true, encoding: .utf8)
        let read = try XCTUnwrap(readCVSStatuses(in: tmp))
        XCTAssertEqual(read.statuses["a.tex"], .clean)
        XCTAssertEqual(read.statuses["b.tex"], .ignored, "the directory's .cvsignore applies")
        XCTAssertEqual(read.statuses[".cvsignore"], .modified, "hidden files are included")
        XCTAssertEqual(read.statuses["CVS"], .ignored)
        XCTAssertEqual(read.malformed, ["bad"])
    }
}
