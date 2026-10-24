import Foundation
import CryptoKit

// CVS working-copy logic: checkout detection for the context menu's "Open in
// lazycvs", and the per-file status signs (M, A, R, C, ?) shown in yazi's
// file list (bundled cvs.yazi, via `conspectus --cvs-status`) and in the
// pane's folder listing. One home for both readers.
//
// The status is read from the working copy alone — `CVS/Entries`, its
// pending `CVS/Entries.Log`, mtimes and the cvsignore lists — never from the
// server: that is what makes it cheap enough to run on every directory yazi
// enters. What it therefore cannot see: a newer revision on the server
// ("needs update"), and the server-side `CVSROOT/cvsignore`.

/// The CVS working directory a right-clicked item belongs to: the item
/// itself when it is a directory, else its parent — returned only when that
/// directory holds a `CVS/Root` marker (the file CVS writes into every
/// checked-out directory). nil means "not a CVS checkout", the normal case
/// for most paths, so the caller simply leaves the menu item out.
public func cvsWorkingDir(for path: String) -> String? {
    let dir = isDirectory(path) ? path : (path as NSString).deletingLastPathComponent
    let root = (dir as NSString).appendingPathComponent("CVS/Root")
    return FileManager.default.fileExists(atPath: root) ? dir : nil
}

/// State of one directory entry relative to its CVS checkout, as far as the
/// working copy alone can tell (see the file header for what it cannot).
public enum CVSFileStatus: String, CaseIterable {
    /// Edited since checkout (mtime differs from the Entries timestamp), or
    /// merged by an update ("Result of merge").
    case modified
    /// `cvs add`ed, not yet committed (revision `0`).
    case added
    /// `cvs remove`d, not yet committed (revision `-…`); usually the file is
    /// already gone, then nothing displays it.
    case removed
    /// An update merged with conflicts ("Result of merge+…") and the file
    /// still holds conflict markers — CVS's own test (`cvs update` prints `C`).
    case conflict
    /// On disk, not in Entries, not ignored: `?` in `cvs update`.
    case unknown
    /// On disk, not in Entries, matched by a cvsignore pattern.
    case ignored
    /// The server holds a newer revision (`U`/`P` in `cvs -n update`) — the
    /// one state that needs the server; it comes from `parseCVSDryRun`, is
    /// cached (`CVSRemoteResult`) and overlays the local states.
    case needsUpdate = "needs-update"
    /// Checked out and unchanged.
    case clean

    /// The letter `cvs -n update` prints for this state; "" where it prints
    /// nothing (clean, ignored).
    public var sign: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .removed: return "R"
        case .conflict: return "C"
        case .unknown: return "?"
        case .needsUpdate: return "U"
        case .ignored, .clean: return ""
        }
    }
}

/// One line of `CVS/Entries`: `/name/revision/timestamp/options/tagdate` for
/// a file, `D/name////` for a subdirectory.
public struct CVSEntry: Equatable {
    public let name: String
    public let isDir: Bool
    /// "1.4"; "0" when added; "-1.4" when removed. Empty for directories.
    public let revision: String
    /// The file's mtime at checkout in asctime form, UTC
    /// ("Sun Feb 18 19:33:43 2024"), or a marker: "dummy timestamp",
    /// "Initial <name>", "Result of merge", "Result of merge+<asctime>".
    /// Empty for directories.
    public let timestamp: String

    public init(name: String, isDir: Bool, revision: String = "", timestamp: String = "") {
        self.name = name
        self.isDir = isDir
        self.revision = revision
        self.timestamp = timestamp
    }
}

/// Parsed `CVS/Entries` (+ `Entries.Log`) of one directory.
public struct CVSEntriesFile: Equatable {
    /// Entries by name.
    public let entries: [String: CVSEntry]
    /// Lines that fit neither entry form — reported, not guessed at.
    public let malformed: [String]
}

/// Parse `CVS/Entries`, then apply `CVS/Entries.Log` on top (`A <entry>`
/// adds, `R <entry>` removes — CVS writes it during an operation and folds it
/// into Entries later). A lone `D` line (meaning "subdirectories are listed")
/// and empty lines are skipped; anything else unparseable lands in
/// `malformed`.
public func parseCVSEntries(_ entries: String, log: String? = nil) -> CVSEntriesFile {
    var byName: [String: CVSEntry] = [:]
    var malformed: [String] = []
    for line in entries.split(separator: "\n", omittingEmptySubsequences: true) {
        if line == "D" { continue }
        guard let e = parseCVSEntryLine(String(line)) else { malformed.append(String(line)); continue }
        byName[e.name] = e
    }
    for line in (log ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
        let op = line.prefix(2)
        guard op == "A " || op == "R ", let e = parseCVSEntryLine(String(line.dropFirst(2))) else {
            malformed.append(String(line)); continue
        }
        if op == "A " { byName[e.name] = e } else { byName[e.name] = nil }
    }
    return CVSEntriesFile(entries: byName, malformed: malformed)
}

/// One Entries line → entry, nil if it is neither form.
private func parseCVSEntryLine(_ line: String) -> CVSEntry? {
    let isDir = line.hasPrefix("D/")
    let body = isDir ? String(line.dropFirst(1)) : line
    let f = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    // ["", name, revision, timestamp, options, tagdate]
    guard f.count >= 5, f[0].isEmpty, !f[1].isEmpty else { return nil }
    return isDir ? CVSEntry(name: f[1], isDir: true)
                 : CVSEntry(name: f[1], isDir: false, revision: f[2], timestamp: f[3])
}

/// A date in the form CVS stores it in Entries: asctime, UTC, the day padded
/// with a space ("Mon Mar  4 09:05:00 2024"). CVS decides "modified" by
/// comparing exactly this string, so the status does the same.
public func cvsTimestamp(_ date: Date) -> String {
    var t = time_t(date.timeIntervalSince1970.rounded(.down))
    var tm = tm()
    gmtime_r(&t, &tm)
    var buf = [CChar](repeating: 0, count: 64)
    let n = strftime(&buf, buf.count, "%a %b %e %H:%M:%S %Y", &tm)
    precondition(n > 0, "strftime produced nothing for \(date)")
    return String(cString: buf)
}

/// Status of a file that has an Entries line, given its current mtime.
/// `hasConflictMarkers` reads the file; it is called only after a conflicted
/// merge, the way CVS itself looks: an untouched file is a conflict, an
/// edited one stays a conflict while the markers are in it (checked against
/// cvs 1.12, 2026-10-18).
public func cvsFileStatus(_ e: CVSEntry, mtime: Date, hasConflictMarkers: () -> Bool) -> CVSFileStatus {
    if e.revision == "0" { return .added }
    if e.revision.hasPrefix("-") { return .removed }
    let now = cvsTimestamp(mtime)
    if let plus = e.timestamp.firstIndex(of: "+") {
        if e.timestamp[e.timestamp.index(after: plus)...] == now { return .conflict }
        return hasConflictMarkers() ? .conflict : .modified
    }
    return e.timestamp == now ? .clean : .modified
}

/// True if `text` holds an rcsmerge conflict block line: `<<<<<<< `,
/// `=======` or `>>>>>>> ` at the start of a line (CVS's `file_has_markers`).
public func containsConflictMarkers(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains {
        $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") || $0 == "======="
    }
}

/// CVS's built-in ignore list, as compiled into the installed cvs
/// (`strings $(which cvs)`, 1.12 Homebrew build, checked 2026-10-18 —
/// Apple's `._*` included). `.` and `..` are left out: never listed.
public let cvsDefaultIgnore = [
    "core", "RCSLOG", "tags", "TAGS", "RCS", "SCCS", ".make.state", ".nse_depinfo",
    "#*", ".#*", "cvslog.*", ",*", "CVS", "CVS.adm", ".del-*", "*.a", "*.olb", "*.o",
    "*.obj", "*.so", "*.Z", "*~", "*.old", "*.elc", "*.ln", "*.bak", "*.BAK", "*.orig",
    "*.rej", "*.exe", "_$*", "*$", "._*",
]

/// The effective ignore patterns, built the way CVS builds them: the default
/// list, then `~/.cvsignore`, then `$CVSIGNORE`, then the directory's
/// `.cvsignore`; each source is whitespace-separated, and a `!` clears
/// everything collected so far.
public func cvsIgnorePatterns(home: String?, env: String?, dir: String?) -> [String] {
    var out = cvsDefaultIgnore
    for source in [home, env, dir] {
        for token in (source ?? "").split(whereSeparator: { $0.isWhitespace }) {
            if token == "!" { out.removeAll() } else { out.append(String(token)) }
        }
    }
    return out
}

/// True if `name` matches one of the shell-glob `patterns` (fnmatch, as CVS does).
public func cvsIgnored(_ name: String, patterns: [String]) -> Bool {
    patterns.contains { fnmatch($0, name, 0) == 0 }
}

/// Status of every entry on disk in a checkout directory. Pure: the caller
/// supplies the parsed Entries, the directory listing (names, dir flags,
/// mtimes), which subdirectories carry their own `CVS/` (a checked-out
/// subdir an old client did not record as a `D` line), and the ignore
/// patterns, and `hasConflictMarkers(name)` (see `cvsFileStatus`). Entries
/// without a file on disk are left out — nothing lists them.
public func cvsStatuses(entries: CVSEntriesFile, onDisk: [DirEntry],
                        checkedOutSubdirs: Set<String>, ignore: [String],
                        hasConflictMarkers: (String) -> Bool) -> [String: CVSFileStatus] {
    var out: [String: CVSFileStatus] = [:]
    for item in onDisk {
        if let e = entries.entries[item.name] {
            if e.isDir { out[item.name] = .clean; continue }
            // An entry without a readable mtime vanished mid-listing; show it as edited.
            out[item.name] = item.modified.map {
                cvsFileStatus(e, mtime: $0, hasConflictMarkers: { hasConflictMarkers(item.name) })
            } ?? .modified
        } else if item.isDir && checkedOutSubdirs.contains(item.name) {
            out[item.name] = .clean
        } else {
            out[item.name] = cvsIgnored(item.name, patterns: ignore) ? .ignored : .unknown
        }
    }
    return out
}

/// What `readCVSStatuses` knows about one checkout directory.
public struct CVSDirectoryState {
    /// Status of every entry on disk (see `cvsStatuses`).
    public let statuses: [String: CVSFileStatus]
    /// Entries lines that fit neither form — for the caller to warn about.
    public let malformed: [String]
    /// The parsed Entries, for callers that need a file's revision.
    public let entries: CVSEntriesFile
}

/// Statuses of a directory read from disk; nil when `dir` is not a CVS
/// checkout (no `CVS/Entries`), the normal case outside `~/cvsrepo`.
/// Hidden files are included (`.cvsignore` itself is usually tracked).
/// `dir` may be a symlink to the checkout (see `directoryURL`).
///
/// Side effects: reads the directory, its `CVS/Entries`, `CVS/Entries.Log`,
/// `.cvsignore`, `~/.cvsignore` and `$CVSIGNORE`, and — after a conflicted
/// merge only — the merged file.
public func readCVSStatuses(in dir: String) -> CVSDirectoryState? {
    let ns = dir as NSString
    // Deliberate try?: no Entries is the normal "not a checkout" answer.
    guard let entriesText = try? String(contentsOfFile: ns.appendingPathComponent("CVS/Entries"),
                                        encoding: .utf8) else { return nil }
    // Deliberate try? (all three): each file is optional, absence is the normal case.
    let log = try? String(contentsOfFile: ns.appendingPathComponent("CVS/Entries.Log"), encoding: .utf8)
    let homeIgnore = try? String(contentsOfFile: (NSHomeDirectory() as NSString)
        .appendingPathComponent(".cvsignore"), encoding: .utf8)
    let dirIgnore = try? String(contentsOfFile: ns.appendingPathComponent(".cvsignore"), encoding: .utf8)
    let parsed = parseCVSEntries(entriesText, log: log)
    let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
    // Deliberate try?: a directory that vanished between the Entries read and
    // now simply has no entries to mark.
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: directoryURL(dir), includingPropertiesForKeys: keys)) ?? []
    var subdirs = Set<String>()
    let onDisk = urls.map { url -> DirEntry in
        // Deliberate try?: prefetched keys; a miss means the entry vanished.
        let v = try? url.resourceValues(forKeys: Set(keys))
        let isDir = v?.isDirectory ?? false
        if isDir, FileManager.default.fileExists(atPath: url.appendingPathComponent("CVS/Entries").path) {
            subdirs.insert(url.lastPathComponent)
        }
        return DirEntry(name: url.lastPathComponent, isDir: isDir, modified: v?.contentModificationDate)
    }
    let patterns = cvsIgnorePatterns(home: homeIgnore, env: ProcessInfo.processInfo.environment["CVSIGNORE"],
                                     dir: dirIgnore)
    let markers = { (name: String) -> Bool in
        // Deliberate try?: an unreadable (binary, vanished) file holds no markers to show.
        (try? String(contentsOfFile: ns.appendingPathComponent(name), encoding: .utf8))
            .map(containsConflictMarkers) ?? false
    }
    return CVSDirectoryState(
        statuses: cvsStatuses(entries: parsed, onDisk: onDisk, checkedOutSubdirs: subdirs, ignore: patterns,
                              hasConflictMarkers: markers),
        malformed: parsed.malformed, entries: parsed)
}

// MARK: - One file's line: "paper.tex  1.4 — current (checked today 10:32)"

/// Everything the preview's CVS line is built from. `remote` is the cached
/// server check of the file's directory (nil: none yet); `remoteEnabled`
/// false means the server is never asked (CONSPECTUS_CVS_REMOTE=off).
public struct CVSFileState: Equatable {
    public let name: String
    /// Entries revision ("1.4"; "0" when added); nil when not in CVS.
    public let revision: String?
    public let local: CVSFileStatus
    public let remote: CVSRemoteResult?
    public let remoteEnabled: Bool

    public init(name: String, revision: String?, local: CVSFileStatus, remote: CVSRemoteResult?,
                remoteEnabled: Bool) {
        self.name = name
        self.revision = revision
        self.local = local
        self.remote = remote
        self.remoteEnabled = remoteEnabled
    }
}

/// The line above a previewed file, in two parts so the caller can color
/// the verdict: `head` = name + revision, `verdict` = the answer to "is this
/// the current version?" with the server check's age. The verdict's
/// `status` names what to color it like (`.clean` for "current").
public struct CVSFileLine: Equatable {
    public let head: String
    public let verdict: String
    public let status: CVSFileStatus
}

/// Build the line. The local state wins when it says more than the server
/// (a modified file is "modified" whatever the server holds — that is also
/// what `cvs -n update` prints); otherwise the server check answers, and
/// its absence is said as such, never as "current".
public func cvsFileLine(_ f: CVSFileState, now: Date, timeZone: TimeZone = .current) -> CVSFileLine {
    let head = f.revision.map { "\(f.name)  \($0)" } ?? f.name
    // The listing's date format, minus its column padding.
    func checked(_ r: CVSRemoteResult) -> String {
        "checked " + listingDate(r.checked, now: now, timeZone: timeZone)
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
    switch f.local {
    case .unknown: return CVSFileLine(head: head, verdict: "not in CVS", status: .unknown)
    case .ignored: return CVSFileLine(head: head, verdict: "ignored by CVS", status: .ignored)
    case .added: return CVSFileLine(head: head, verdict: "added, not committed", status: .added)
    case .removed: return CVSFileLine(head: head, verdict: "removed, not committed", status: .removed)
    case .conflict: return CVSFileLine(head: head, verdict: "conflict markers in the file", status: .conflict)
    case .modified:
        let server = f.remote.map { $0.error == nil ? " · server has nothing newer (\(checked($0)))" : "" } ?? ""
        return CVSFileLine(head: head, verdict: "modified locally, not committed" + server, status: .modified)
    case .needsUpdate:
        let when = f.remote.map { " (\(checked($0)))" } ?? ""
        return CVSFileLine(head: head, verdict: "newer on the server" + when, status: .needsUpdate)
    case .clean:
        guard f.remoteEnabled else {
            return CVSFileLine(head: head, verdict: "unchanged locally; server not asked (CONSPECTUS_CVS_REMOTE=off)",
                               status: .clean)
        }
        guard let r = f.remote else {
            return CVSFileLine(head: head, verdict: "unchanged locally; server not checked yet", status: .clean)
        }
        if let err = r.error {
            return CVSFileLine(head: head, verdict: "unchanged locally; server check failed (\(checked(r)): \(err))",
                               status: .clean)
        }
        return CVSFileLine(head: head, verdict: "current (\(checked(r)))", status: .clean)
    }
}

// MARK: - Server side: `cvs -n -q update -l`, cached per directory

/// Files of one directory the server has newer revisions of (`U` update, `P`
/// patch in a dry run). Everything else the dry run prints (`M A R C ?`) is
/// local and already covered by `cvsStatuses`; it is ignored here.
/// `-l` keeps it to the directory itself, so names carry no slash.
public func parseCVSDryRun(_ stdout: String) -> Set<String> {
    var out = Set<String>()
    for line in stdout.split(separator: "\n") {
        guard line.count > 2, line.hasPrefix("U ") || line.hasPrefix("P ") else { continue }
        out.insert(String(line.dropFirst(2)))
    }
    return out
}

/// One server check of a directory, as cached on disk and printed by
/// `conspectus --cvs-remote`. A failed check (server unreachable, timeout)
/// is a result too — cached briefly so a dead server is not asked for every
/// directory — and carries `error` instead of names.
public struct CVSRemoteResult: Equatable {
    public let checked: Date
    public let needsUpdate: Set<String>
    public let error: String?

    public init(checked: Date, needsUpdate: Set<String>, error: String? = nil) {
        self.checked = checked
        self.needsUpdate = needsUpdate
        self.error = error
    }

    /// Wire and cache format, one field per line: `checked\t<unix seconds>`,
    /// then either `error\t<message>` or `needs-update\t<name>` per file.
    public func serialized() -> String {
        var lines = ["checked\t\(Int(checked.timeIntervalSince1970))"]
        if let error = error { lines.append("error\t\(error)") }
        lines += needsUpdate.sorted().map { "needs-update\t\($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Inverse of `serialized`; nil for anything that does not start with a
    /// `checked` line or holds an unknown field — a damaged cache file is
    /// treated as absent by the caller, never half-read.
    public static func parse(_ text: String) -> CVSRemoteResult? {
        var checked: Date?
        var names = Set<String>()
        var error: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "checked":
                guard checked == nil, let secs = Int(parts[1]) else { return nil }
                checked = Date(timeIntervalSince1970: TimeInterval(secs))
            case "error": error = String(parts[1])
            case "needs-update": names.insert(String(parts[1]))
            default: return nil
            }
        }
        guard let at = checked else { return nil }
        return CVSRemoteResult(checked: at, needsUpdate: names, error: error)
    }

    /// Still worth showing at `now`: a good check within `ttl`, a failed one
    /// within `errorTTL` (short — the server may be back).
    public func isFresh(now: Date, ttl: TimeInterval, errorTTL: TimeInterval) -> Bool {
        now.timeIntervalSince(checked) < (error == nil ? ttl : errorTTL)
    }
}

/// Cache file for a directory's server check: one file per directory under
/// `cacheDir`, named by a hash of the path (paths are long and hold `/`);
/// the file itself starts with the path so it stays inspectable.
public func cvsRemoteCachePath(for dir: String, cacheDir: String) -> String {
    let digest = SHA256.hash(data: Data(dir.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    return (cacheDir as NSString).appendingPathComponent(digest)
}

/// Read a directory's cached server check; nil when there is none or it is
/// unreadable (both the normal case before the first check). Side effects:
/// reads the cache file.
public func readCVSRemoteCache(for dir: String, cacheDir: String) -> CVSRemoteResult? {
    let path = cvsRemoteCachePath(for: dir, cacheDir: cacheDir)
    // Deliberate try?: no cache yet is the normal case.
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    // First line is the directory (see `writeCVSRemoteCache`); a collision
    // between two paths would show up here, so it is checked, not assumed.
    guard let nl = text.firstIndex(of: "\n"), text[..<nl] == "dir\t" + dir else { return nil }
    return CVSRemoteResult.parse(String(text[text.index(after: nl)...]))
}

/// Write a directory's server check to its cache file. Throws on an
/// unwritable cache dir — the caller reports it. Side effects: creates
/// `cacheDir`, writes the file.
public func writeCVSRemoteCache(_ result: CVSRemoteResult, for dir: String, cacheDir: String) throws {
    try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    try ("dir\t" + dir + "\n" + result.serialized())
        .write(toFile: cvsRemoteCachePath(for: dir, cacheDir: cacheDir), atomically: true, encoding: .utf8)
}
