import Foundation

// Git working-copy logic, the git twin of CVS.swift: repository detection
// for the line above a previewed file and for VCS Update…, git's porcelain
// letters mapped onto the sign vocabulary the strip colors
// (`CVSFileStatus`), the cached server check (`git fetch`, then the files
// the upstream branch has newer content for) and the line's wording.
// Spawning git is the executable's job (main.swift: `runGitRemoteCheck`,
// `readGitFileLocal`); everything here is parsing and words. Unlike CVS,
// nothing feeds yazi's file list — git.yazi already shows the local signs.

/// The git repository `path` belongs to: `path` itself when it is a
/// directory, else its parent, then upwards, the first holding a `.git`
/// entry (a directory, or the file a worktree or submodule carries). nil
/// outside any repository. A symlink to a repository counts as that
/// repository: the probe goes through the link, and the walk stops there,
/// before reaching the link's own parents. Side effects: reads the
/// directory chain.
public func gitWorkingDir(for path: String) -> String? {
    var dir = isDirectory(path) ? path : (path as NSString).deletingLastPathComponent
    while !dir.isEmpty {
        if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) { return dir }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir { return nil }
        dir = parent
    }
    return nil
}

/// One path's entry of `git status --porcelain=v1 --ignored`, read into
/// the sign vocabulary: `??` unknown (untracked), `!!` ignored, a `U` on
/// either side or `AA`/`DD` conflict, `A` added, `D` on either side
/// removed, everything else (M, R, T, C — index or worktree) modified. No
/// line at all is clean — the caller asked for one path, so the first
/// entry is the answer.
public func parseGitPorcelainStatus(_ stdout: String) -> CVSFileStatus {
    guard let line = stdout.split(separator: "\n").first, line.count >= 2 else { return .clean }
    let x = line[line.startIndex], y = line[line.index(after: line.startIndex)]
    switch (x, y) {
    case ("?", "?"): return .unknown
    case ("!", "!"): return .ignored
    case ("A", "A"), ("D", "D"): return .conflict
    case _ where x == "U" || y == "U": return .conflict
    case ("A", _): return .added
    case ("D", _), (_, "D"): return .removed
    default: return .modified
    }
}

/// `git rev-list --left-right --count HEAD...@{u}` prints `<ahead>\t<behind>`;
/// nil for anything else (no upstream, garbage).
public func parseGitAheadBehind(_ stdout: String) -> (ahead: Int, behind: Int)? {
    let parts = stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
    guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
    return (a, b)
}

/// The last commit that touched a file: short hash and author date, from
/// `git log -1 --format=%h%x09%ct -- <path>`.
public struct GitCommitStamp: Equatable {
    public let hash: String
    public let date: Date

    public init(hash: String, date: Date) {
        self.hash = hash
        self.date = date
    }

    /// nil for no output (a file git has never committed) or a malformed line.
    public static func parse(_ stdout: String) -> GitCommitStamp? {
        let parts = stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        guard parts.count == 2, !parts[0].isEmpty, let secs = Int(parts[1]) else { return nil }
        return GitCommitStamp(hash: String(parts[0]), date: Date(timeIntervalSince1970: TimeInterval(secs)))
    }
}

/// One server check of a repository, cached per repository root. `changed`
/// holds the repo-relative paths the upstream branch has newer content for
/// (`git diff --name-only HEAD...@{u}`), so the line answers per file, not
/// per repository; `behind`/`ahead` are the commit counts against
/// `upstream`. A failed check (no upstream, fetch refused, timeout) is a
/// result too — cached briefly — and carries `error`.
public struct GitRemoteResult: Equatable {
    public let checked: Date
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let changed: Set<String>
    public let error: String?

    public init(checked: Date, upstream: String?, ahead: Int, behind: Int, changed: Set<String>,
                error: String? = nil) {
        self.checked = checked
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changed = changed
        self.error = error
    }

    /// Cache format, one field per line: `checked\t<unix seconds>`, then
    /// `error\t<message>` or `upstream\t<name>`, `ahead\t<n>`, `behind\t<n>`
    /// and one `changed\t<path>` per file.
    public func serialized() -> String {
        var lines = ["checked\t\(Int(checked.timeIntervalSince1970))"]
        if let error = error { lines.append("error\t\(error)") }
        if let upstream = upstream { lines.append("upstream\t\(upstream)") }
        lines.append("ahead\t\(ahead)")
        lines.append("behind\t\(behind)")
        lines += changed.sorted().map { "changed\t\($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Inverse of `serialized`; nil for a text that does not start with a
    /// `checked` line, lacks the counts, or holds an unknown field — a
    /// damaged cache file is treated as absent, never half-read.
    public static func parse(_ text: String) -> GitRemoteResult? {
        var checked: Date?, upstream: String?, ahead: Int?, behind: Int?, error: String?
        var changed = Set<String>()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "checked":
                guard checked == nil, let secs = Int(parts[1]) else { return nil }
                checked = Date(timeIntervalSince1970: TimeInterval(secs))
            case "error": error = String(parts[1])
            case "upstream": upstream = String(parts[1])
            case "ahead": guard let n = Int(parts[1]) else { return nil }; ahead = n
            case "behind": guard let n = Int(parts[1]) else { return nil }; behind = n
            case "changed": changed.insert(String(parts[1]))
            default: return nil
            }
        }
        guard let at = checked, let a = ahead, let b = behind else { return nil }
        return GitRemoteResult(checked: at, upstream: upstream, ahead: a, behind: b, changed: changed, error: error)
    }

    /// See `remoteCheckIsFresh`.
    public func isFresh(now: Date, ttl: TimeInterval, errorTTL: TimeInterval) -> Bool {
        remoteCheckIsFresh(checked: checked, error: error, now: now, ttl: ttl, errorTTL: errorTTL)
    }
}

/// Read a repository's cached server check; nil when there is none, it is
/// unreadable or damaged. Side effects: reads the cache file.
public func readGitRemoteCache(for root: String, cacheDir: String) -> GitRemoteResult? {
    readRemoteCacheText(for: root, cacheDir: cacheDir).flatMap(GitRemoteResult.parse)
}

/// Write a repository's server check to its cache file; throws on an
/// unwritable cache dir. Side effects: creates `cacheDir`, writes the file.
public func writeGitRemoteCache(_ result: GitRemoteResult, for root: String, cacheDir: String) throws {
    try writeRemoteCacheText(result.serialized(), for: root, cacheDir: cacheDir)
}

/// Everything the preview's git line is built from. `repoPath` is the
/// file's path relative to the repository root (what `changed` lists);
/// `commit` is nil for a file git never committed; `remote` the cached
/// check of the repository (nil: none yet); `remoteEnabled` false means the
/// server is never asked (CONSPECTUS_GIT_REMOTE=off).
public struct GitFileState: Equatable {
    public let name: String
    public let repoPath: String
    public let commit: GitCommitStamp?
    public let local: CVSFileStatus
    public let remote: GitRemoteResult?
    public let remoteEnabled: Bool

    public init(name: String, repoPath: String, commit: GitCommitStamp?, local: CVSFileStatus,
                remote: GitRemoteResult?, remoteEnabled: Bool) {
        self.name = name
        self.repoPath = repoPath
        self.commit = commit
        self.local = local
        self.remote = remote
        self.remoteEnabled = remoteEnabled
    }
}

/// Build the git line, the same contract as `cvsFileLine`: the local state
/// wins when it says more than the server; otherwise the fetch answers —
/// per file, through `changed` — and its absence is said as such, never as
/// "current". Head: name + last commit (`efc8c72 30.09. 2025`).
public func gitFileLine(_ f: GitFileState, now: Date, timeZone: TimeZone = .current) -> VCSFileLine {
    let head = f.commit.map { "\(f.name)  \($0.hash) \(remoteCheckAge($0.date, now: now, timeZone: timeZone))" }
        ?? f.name
    func fetched(_ r: GitRemoteResult) -> String {
        "fetched " + remoteCheckAge(r.checked, now: now, timeZone: timeZone)
    }
    func origin(_ r: GitRemoteResult) -> String { r.upstream ?? "upstream" }
    func commits(_ n: Int) -> String { n == 1 ? "1 commit" : "\(n) commits" }
    switch f.local {
    case .unknown: return VCSFileLine(head: head, verdict: "not in git (untracked)", status: .unknown)
    case .ignored: return VCSFileLine(head: head, verdict: "ignored by git", status: .ignored)
    case .added: return VCSFileLine(head: head, verdict: "added, not committed", status: .added)
    case .removed: return VCSFileLine(head: head, verdict: "deleted, not committed", status: .removed)
    case .conflict: return VCSFileLine(head: head, verdict: "merge conflict, unresolved", status: .conflict)
    case .modified:
        var server = ""
        if let r = f.remote, r.error == nil {
            server = r.changed.contains(f.repoPath)
                ? " · also newer on \(origin(r)) (\(fetched(r)))"
                : " · \(origin(r)) has nothing newer (\(fetched(r)))"
        }
        return VCSFileLine(head: head, verdict: "modified locally, not committed" + server, status: .modified)
    case .needsUpdate, .clean:
        guard f.remoteEnabled else {
            return VCSFileLine(head: head, verdict: "unchanged locally; upstream not asked (CONSPECTUS_GIT_REMOTE=off)",
                               status: .clean)
        }
        guard let r = f.remote else {
            return VCSFileLine(head: head, verdict: "unchanged locally; upstream not checked yet", status: .clean)
        }
        if let err = r.error {
            return VCSFileLine(head: head, verdict: "unchanged locally; fetch failed (\(fetched(r)): \(err))",
                               status: .clean)
        }
        if r.changed.contains(f.repoPath) {
            return VCSFileLine(head: head, verdict: "newer on \(origin(r)) — \(commits(r.behind)) behind (\(fetched(r)))",
                               status: .needsUpdate)
        }
        var tail = ""
        if r.behind > 0 { tail += " · \(origin(r)) is \(commits(r.behind)) ahead, not this file" }
        if r.ahead > 0 { tail += " · \(commits(r.ahead)) to push" }
        return VCSFileLine(head: head, verdict: "current (\(fetched(r)))" + tail, status: .clean)
    }
}
