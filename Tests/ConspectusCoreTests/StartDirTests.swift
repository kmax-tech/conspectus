import XCTest
@testable import ConspectusCore

/// Tests for start-directory resolution (StartDir.swift).
final class StartDirTests: XCTestCase {
    /// Scratch area for the test; recreated per test, removed afterwards.
    private var tmp: String = ""

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "conspectus-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: tmp)
    }

    func testExplicitExistingDirectoryIsUsed() {
        let r = resolveStart(tmp, lastCwdFile: tmp + "/absent", home: "/HOME")
        XCTAssertEqual(r, StartDir(path: tmp))
        XCTAssertNil(r.warning)
    }

    func testExplicitFileResolvesToParentWithReveal() throws {
        let file = tmp + "/a-file"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let r = resolveStart(file, lastCwdFile: tmp + "/absent", home: "/HOME")
        XCTAssertEqual(r.path, tmp, "a file argument starts in the file's parent directory")
        XCTAssertEqual(r.revealFile, file, "the file is handed to yazi as the entry to reveal")
        XCTAssertNil(r.warning, "a file argument is valid input, not a fallback")
    }

    func testExplicitDirectoryHasNoReveal() {
        let r = resolveStart(tmp, lastCwdFile: tmp + "/absent", home: "/HOME")
        XCTAssertNil(r.revealFile)
    }

    func testExplicitMissingPathFallsBackWithWarning() {
        let r = resolveStart(tmp + "/nope", lastCwdFile: tmp + "/absent", home: "/HOME")
        XCTAssertEqual(r.path, "/HOME")
        XCTAssertNotNil(r.warning)
    }

    func testNoArgResumesLastCwd() throws {
        let lastCwd = tmp + "/last-cwd"
        try (tmp + "\n").write(toFile: lastCwd, atomically: true, encoding: .utf8)
        let r = resolveStart(nil, lastCwdFile: lastCwd, home: "/HOME")
        XCTAssertEqual(r, StartDir(path: tmp))
    }

    func testNoArgWithoutLastCwdFileUsesHome() {
        let r = resolveStart(nil, lastCwdFile: tmp + "/absent", home: "/HOME")
        XCTAssertEqual(r, StartDir(path: "/HOME"))
        XCTAssertNil(r.warning, "first run without a last-cwd file is normal, not a warning")
    }

    func testNoArgWithStaleLastCwdUsesHome() throws {
        let lastCwd = tmp + "/last-cwd"
        try (tmp + "/deleted-dir\n").write(toFile: lastCwd, atomically: true, encoding: .utf8)
        let r = resolveStart(nil, lastCwdFile: lastCwd, home: "/HOME")
        XCTAssertEqual(r, StartDir(path: "/HOME"))
    }

    func testEmptyArgBehavesLikeNoArg() {
        let r = resolveStart("", lastCwdFile: tmp + "/absent", home: "/HOME")
        XCTAssertEqual(r, StartDir(path: "/HOME"))
    }

    func testIsDirectory() throws {
        XCTAssertTrue(isDirectory(tmp))
        XCTAssertFalse(isDirectory(tmp + "/absent"))
        let file = tmp + "/f"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(isDirectory(file))
    }
}
