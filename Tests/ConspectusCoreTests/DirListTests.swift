import XCTest
@testable import ConspectusCore

final class DirListTests: XCTestCase {

    // MARK: parseDirList

    func testParsesTrimsAndExpandsTilde() {
        XCTAssertEqual(parseDirList(" ~/mnt/ceph , /Volumes/ceph ,, ", home: "/Users/x"),
                       ["/Users/x/mnt/ceph", "/Volumes/ceph"])
    }

    func testBareTildeIsHome() {
        XCTAssertEqual(parseDirList("~", home: "/Users/x"), ["/Users/x"])
    }

    func testEmptyValueYieldsNothing() {
        XCTAssertEqual(parseDirList("", home: "/Users/x"), [])
        XCTAssertEqual(parseDirList(" , ,", home: "/Users/x"), [])
    }

    func testTrailingSlashesDropped() {
        XCTAssertEqual(parseDirList("/Volumes/ceph//", home: "/Users/x"), ["/Volumes/ceph"])
    }

    func testRootSurvivesSlashNormalization() {
        XCTAssertEqual(parseDirList("/", home: "/Users/x"), ["/"])
    }

    // MARK: pathIsUnder

    func testMatchesDirItselfAndDescendants() {
        let dirs = ["/Volumes/ceph"]
        XCTAssertTrue(pathIsUnder("/Volumes/ceph", anyOf: dirs))
        XCTAssertTrue(pathIsUnder("/Volumes/ceph/a.txt", anyOf: dirs))
        XCTAssertTrue(pathIsUnder("/Volumes/ceph/deep/nested/b.pdf", anyOf: dirs))
    }

    func testNoFalseMatchOnSiblingWithSamePrefix() {
        XCTAssertFalse(pathIsUnder("/Volumes/cephalon/a.txt", anyOf: ["/Volumes/ceph"]))
    }

    func testUnrelatedPathAndEmptyListDontMatch() {
        XCTAssertFalse(pathIsUnder("/Users/x/doc.md", anyOf: ["/Volumes/ceph"]))
        XCTAssertFalse(pathIsUnder("/Volumes/ceph/a.txt", anyOf: []))
    }

    func testRootCoversEverything() {
        XCTAssertTrue(pathIsUnder("/anything/at/all", anyOf: ["/"]))
    }

    // MARK: toggleSkipDir

    func testToggleAddsUncoveredDir() {
        let r = toggleSkipDir("/Volumes/ceph", in: ["/mnt/nfs"])
        XCTAssertEqual(r.dirs, ["/mnt/nfs", "/Volumes/ceph"])
        XCTAssertTrue(r.nowSkipped)
    }

    func testToggleRemovesExactEntry() {
        let r = toggleSkipDir("/Volumes/ceph", in: ["/mnt/nfs", "/Volumes/ceph"])
        XCTAssertEqual(r.dirs, ["/mnt/nfs"])
        XCTAssertFalse(r.nowSkipped)
    }

    func testToggleDeepInsideRemovesCoveringAncestor() {
        let r = toggleSkipDir("/Volumes/ceph/deep/sub", in: ["/Volumes/ceph", "/mnt/nfs"])
        XCTAssertEqual(r.dirs, ["/mnt/nfs"])
        XCTAssertFalse(r.nowSkipped)
    }

    func testToggleRemovesAllCoveringEntries() {
        let r = toggleSkipDir("/Volumes/ceph/sub", in: ["/Volumes/ceph", "/Volumes/ceph/sub"])
        XCTAssertEqual(r.dirs, [])
        XCTAssertFalse(r.nowSkipped)
    }

    func testToggleTwiceRoundTrips() {
        let on = toggleSkipDir("/Volumes/ceph", in: [])
        XCTAssertTrue(on.nowSkipped)
        let off = toggleSkipDir("/Volumes/ceph", in: on.dirs)
        XCTAssertEqual(off.dirs, [])
        XCTAssertFalse(off.nowSkipped)
    }
}
