import XCTest
@testable import ConspectusCore

/// Note lookup against real temp-dir fixtures — the resolver's contract is
/// filesystem behavior, so the tests build tiny real trees per case.
final class NoteResolverTests: XCTestCase {
    var root = ""

    override func setUpWithError() throws {
        // Symlink-resolved root: /var/tmp is itself a symlink on macOS, and the
        // resolver canonicalizes paths — a pre-resolved root keeps the expected
        // strings comparable to the resolver's output.
        let base = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
        root = (base as NSString).appendingPathComponent("note-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: root)
    }

    /// Create an empty file (plus parent dirs) below the fixture root and
    /// return its absolute path.
    @discardableResult
    private func touch(_ relative: String) throws -> String {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())
        return path
    }

    // MARK: parseNotesDirs

    func testParseNotesDirsDefault() {
        XCTAssertEqual(parseNotesDirs(nil, home: "/Users/x"), ["/Users/x/work/library/notes"])
    }

    func testParseNotesDirsListWithTildeAndSpaces() {
        XCTAssertEqual(parseNotesDirs(" ~/notes , /abs/dir ,, ", home: "/Users/x"),
                       ["/Users/x/notes", "/abs/dir"])
    }

    func testParseNotesDirsEmptyStringYieldsNothing() {
        // An explicitly empty value parses to no dirs — the caller decides
        // whether that warrants a warning + fallback.
        XCTAssertEqual(parseNotesDirs("", home: "/Users/x"), [])
    }

    // MARK: resolveNote — local

    func testSiblingNoteWins() throws {
        let pdf = try touch("proj/paper.pdf")
        let note = try touch("proj/paper.md")
        try touch("proj/notes/paper.md")   // sibling must win over the subdir hit
        XCTAssertEqual(resolveNote(for: pdf, notesDirs: []), note)
    }

    func testSubdirNoteFound() throws {
        let pdf = try touch("proj/paper.pdf")
        let note = try touch("proj/notes/paper.md")
        XCTAssertEqual(resolveNote(for: pdf, notesDirs: []), note)
    }

    func testSubdirSearchIsDepthCapped() throws {
        let pdf = try touch("proj/paper.pdf")
        let atCap = try touch("proj/a/b/c/paper.md")           // depth 3 — found
        XCTAssertEqual(resolveNote(for: pdf, notesDirs: []), atCap)
        try FileManager.default.removeItem(atPath: atCap)
        try touch("proj/a/b/c/d/paper.md")                     // depth 4 — beyond the cap
        XCTAssertNil(resolveNote(for: pdf, notesDirs: []))
    }

    func testHiddenDirsSkipped() throws {
        let pdf = try touch("proj/paper.pdf")
        try touch("proj/.git/paper.md")
        XCTAssertNil(resolveNote(for: pdf, notesDirs: []))
    }

    // MARK: resolveNote — symlink + central

    func testSymlinkedPDFFindsNoteAtRealLocation() throws {
        let realPdf = try touch("library/papers/smith2024.pdf")
        let note = try touch("library/papers/smith2024.md")
        try FileManager.default.createDirectory(atPath: root + "/proj", withIntermediateDirectories: true)
        let link = root + "/proj/smith2024.pdf"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: realPdf)
        XCTAssertEqual(resolveNote(for: link, notesDirs: []), note)
    }

    func testCentralLookupUsesCanonicalStem() throws {
        // Symlink under an alias name: the central lookup must use the real
        // stem, so alias.md in the library is NOT a match, real.md is.
        let realPdf = try touch("library/papers/real.pdf")
        try FileManager.default.createDirectory(atPath: root + "/proj", withIntermediateDirectories: true)
        let link = root + "/proj/alias.pdf"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: realPdf)
        let notesDir = root + "/library/notes"
        try touch("library/notes/alias.md")
        XCTAssertNil(resolveNote(for: link, notesDirs: [notesDir]))
        let note = try touch("library/notes/real.md")
        XCTAssertEqual(resolveNote(for: link, notesDirs: [notesDir]), note)
    }

    func testCentralDirsSearchedInOrder() throws {
        let pdf = try touch("proj/paper.pdf")
        let first = try touch("central1/paper.md")
        try touch("central2/paper.md")
        XCTAssertEqual(resolveNote(for: pdf, notesDirs: [root + "/central1", root + "/central2"]),
                       first)
    }

    func testNoNoteAnywhereIsNil() throws {
        let pdf = try touch("proj/paper.pdf")
        XCTAssertNil(resolveNote(for: pdf, notesDirs: [root + "/missing-dir"]))
    }

    // MARK: defaultNotePath

    func testDefaultNotePathIsSibling() {
        XCTAssertEqual(defaultNotePath(for: "/proj/deep dir/paper.v2.pdf"),
                       "/proj/deep dir/paper.v2.md")
    }
}
