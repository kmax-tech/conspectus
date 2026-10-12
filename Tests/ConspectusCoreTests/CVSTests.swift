import XCTest
@testable import ConspectusCore

/// Tests for CVS working-copy detection (CVS.swift).
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
}
