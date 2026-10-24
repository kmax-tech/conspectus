import XCTest
@testable import ConspectusCore

/// Tests for the git twin of the CVS logic (Git.swift): repository
/// detection, porcelain parsing, the cached server check and the line.
final class GitTests: XCTestCase {
    private var tmp: String = ""
    private let march4 = Date(timeIntervalSince1970: 1_709_543_100)
    private let utc = TimeZone(identifier: "UTC")!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "conspectus-git-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp + "/repo/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmp + "/repo/.git", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: tmp)
    }

    // MARK: Repository detection

    func testWorkingDirIsTheNearestAncestorWithDotGit() throws {
        XCTAssertEqual(gitWorkingDir(for: tmp + "/repo"), tmp + "/repo")
        XCTAssertEqual(gitWorkingDir(for: tmp + "/repo/sub"), tmp + "/repo")
        try "x".write(toFile: tmp + "/repo/sub/a.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(gitWorkingDir(for: tmp + "/repo/sub/a.txt"), tmp + "/repo", "a file resolves to its repository")
        XCTAssertNil(gitWorkingDir(for: "/"), "the walk stops at the root")
    }

    func testWorktreeDotGitFileCountsToo() throws {
        try "gitdir: /elsewhere".write(toFile: tmp + "/wt.git", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: tmp + "/wt", withIntermediateDirectories: true)
        try "gitdir: /elsewhere".write(toFile: tmp + "/wt/.git", atomically: true, encoding: .utf8)
        XCTAssertEqual(gitWorkingDir(for: tmp + "/wt"), tmp + "/wt")
    }

    func testSymlinkToARepositoryIsThatRepository() throws {
        let link = tmp + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tmp + "/repo")
        XCTAssertEqual(gitWorkingDir(for: link), link, "answered at the link, not at the link's parents")
    }

    // MARK: Parsing git's output

    func testPorcelainLettersMapOntoTheSignVocabulary() {
        XCTAssertEqual(parseGitPorcelainStatus(""), .clean)
        XCTAssertEqual(parseGitPorcelainStatus("?? new.txt\n"), .unknown)
        XCTAssertEqual(parseGitPorcelainStatus("!! build/\n"), .ignored)
        XCTAssertEqual(parseGitPorcelainStatus(" M a.txt\n"), .modified)
        XCTAssertEqual(parseGitPorcelainStatus("M  a.txt\n"), .modified, "staged counts as modified too")
        XCTAssertEqual(parseGitPorcelainStatus("R  a.txt -> b.txt\n"), .modified)
        XCTAssertEqual(parseGitPorcelainStatus("A  a.txt\n"), .added)
        XCTAssertEqual(parseGitPorcelainStatus("AM a.txt\n"), .added)
        XCTAssertEqual(parseGitPorcelainStatus(" D a.txt\n"), .removed)
        XCTAssertEqual(parseGitPorcelainStatus("D  a.txt\n"), .removed)
        XCTAssertEqual(parseGitPorcelainStatus("UU a.txt\n"), .conflict)
        XCTAssertEqual(parseGitPorcelainStatus("AA a.txt\n"), .conflict)
        XCTAssertEqual(parseGitPorcelainStatus("DU a.txt\n"), .conflict)
        XCTAssertEqual(parseGitPorcelainStatus("x"), .clean, "a line too short to carry XY is no status")
    }

    func testAheadBehindCountsAndCommitStamp() {
        XCTAssertEqual(parseGitAheadBehind("2\t3\n")?.ahead, 2)
        XCTAssertEqual(parseGitAheadBehind("2\t3\n")?.behind, 3)
        XCTAssertNil(parseGitAheadBehind(""))
        XCTAssertNil(parseGitAheadBehind("fatal: no upstream\n"))
        XCTAssertEqual(GitCommitStamp.parse("efc8c72\t1709543100\n"), GitCommitStamp(hash: "efc8c72", date: march4))
        XCTAssertNil(GitCommitStamp.parse(""), "never committed")
        XCTAssertNil(GitCommitStamp.parse("efc8c72\tyesterday"))
    }

    // MARK: Server check, cached per repository

    func testRemoteResultRoundTripsAndRejectsDamage() {
        let r = GitRemoteResult(checked: march4, upstream: "origin/master", ahead: 1, behind: 2,
                                changed: ["b.kdbx", "a.txt"])
        XCTAssertEqual(r.serialized(),
                       "checked\t1709543100\nupstream\torigin/master\nahead\t1\nbehind\t2\nchanged\ta.txt\nchanged\tb.kdbx\n")
        XCTAssertEqual(GitRemoteResult.parse(r.serialized()), r)
        let e = GitRemoteResult(checked: march4, upstream: nil, ahead: 0, behind: 0, changed: [], error: "no upstream branch")
        XCTAssertEqual(GitRemoteResult.parse(e.serialized()), e)
        XCTAssertNil(GitRemoteResult.parse(""), "no checked line")
        XCTAssertNil(GitRemoteResult.parse("checked\t1\n"), "counts missing")
        XCTAssertNil(GitRemoteResult.parse("checked\t1\nahead\t0\nbehind\tmany\n"), "bad count")
        XCTAssertNil(GitRemoteResult.parse("checked\t1\nahead\t0\nbehind\t0\nbogus\ty\n"), "unknown field")
        XCTAssertTrue(e.isFresh(now: march4 + 59, ttl: 300, errorTTL: 60))
        XCTAssertFalse(e.isFresh(now: march4 + 60, ttl: 300, errorTTL: 60), "errors expire on the short TTL")
    }

    func testRemoteCacheIsKeyedByRepositoryAndSeparateFromCVS() throws {
        let cache = tmp + "/cache"
        let r = GitRemoteResult(checked: march4, upstream: "origin/main", ahead: 0, behind: 1, changed: ["x"])
        try writeGitRemoteCache(r, for: "/repo", cacheDir: cache)
        XCTAssertEqual(readGitRemoteCache(for: "/repo", cacheDir: cache), r)
        XCTAssertNil(readGitRemoteCache(for: "/other", cacheDir: cache))
        XCTAssertNil(readCVSRemoteCache(for: "/repo", cacheDir: cache),
                     "a git result is no CVS result — the formats reject each other")
    }

    // MARK: The preview's line

    private func line(_ local: CVSFileStatus, remote: GitRemoteResult?, enabled: Bool = true,
                      commit: GitCommitStamp? = GitCommitStamp(hash: "efc8c72", date: Date(timeIntervalSince1970: 1_709_543_100)))
        -> VCSFileLine {
        gitFileLine(GitFileState(name: "a.kdbx", repoPath: "sub/a.kdbx", commit: commit, local: local,
                                 remote: remote, remoteEnabled: enabled), now: march4 + 3600, timeZone: utc)
    }

    func testLineSaysCurrentOnlyWithAGoodFetch() {
        let ok = GitRemoteResult(checked: march4, upstream: "origin/master", ahead: 0, behind: 0, changed: [])
        XCTAssertEqual(line(.clean, remote: ok),
                       VCSFileLine(head: "a.kdbx  efc8c72 today 09:05", verdict: "current (fetched today 09:05)", status: .clean))
        XCTAssertEqual(line(.clean, remote: nil).verdict, "unchanged locally; upstream not checked yet")
        XCTAssertEqual(line(.clean, remote: nil, enabled: false).verdict,
                       "unchanged locally; upstream not asked (CONSPECTUS_GIT_REMOTE=off)")
        let bad = GitRemoteResult(checked: march4, upstream: nil, ahead: 0, behind: 0, changed: [], error: "no upstream branch")
        XCTAssertEqual(line(.clean, remote: bad).verdict,
                       "unchanged locally; fetch failed (fetched today 09:05: no upstream branch)")
        XCTAssertEqual(line(.unknown, remote: ok, commit: nil),
                       VCSFileLine(head: "a.kdbx", verdict: "not in git (untracked)", status: .unknown))
    }

    func testLineAnswersPerFileNotPerRepository() {
        let thisFile = GitRemoteResult(checked: march4, upstream: "origin/master", ahead: 0, behind: 3,
                                       changed: ["sub/a.kdbx", "README.md"])
        XCTAssertEqual(line(.clean, remote: thisFile),
                       VCSFileLine(head: "a.kdbx  efc8c72 today 09:05",
                                   verdict: "newer on origin/master — 3 commits behind (fetched today 09:05)",
                                   status: .needsUpdate))
        let otherFiles = GitRemoteResult(checked: march4, upstream: "origin/master", ahead: 2, behind: 1,
                                         changed: ["README.md"])
        XCTAssertEqual(line(.clean, remote: otherFiles).verdict,
                       "current (fetched today 09:05) · origin/master is 1 commit ahead, not this file · 2 commits to push")
        XCTAssertEqual(line(.modified, remote: thisFile).verdict,
                       "modified locally, not committed · also newer on origin/master (fetched today 09:05)")
        XCTAssertEqual(line(.modified, remote: otherFiles).verdict,
                       "modified locally, not committed · origin/master has nothing newer (fetched today 09:05)")
        XCTAssertEqual(line(.modified, remote: nil).verdict, "modified locally, not committed")
        XCTAssertEqual(line(.conflict, remote: thisFile).status, .conflict)
        XCTAssertEqual(line(.ignored, remote: thisFile).verdict, "ignored by git")
    }
}
