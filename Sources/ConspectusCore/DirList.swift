import Foundation

// Directory-list parsing and prefix matching — shared by the env vars that
// name sets of directories (CONSPECTUS_NOTES_DIRS, CONSPECTUS_PREVIEW_SKIP_DIRS).

/// Parse a comma-separated directory list: whitespace trimmed, tilde expanded
/// against `home`, trailing slashes dropped (so matching never depends on how
/// the user typed the path), empty entries dropped. Pure.
public func parseDirList(_ raw: String, home: String = NSHomeDirectory()) -> [String] {
    return raw.split(separator: ",").compactMap { part in
        var dir = part.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return nil }
        if dir == "~" {
            dir = home
        } else if dir.hasPrefix("~/") {
            dir = (home as NSString).appendingPathComponent(String(dir.dropFirst(2)))
        }
        while dir.count > 1, dir.hasSuffix("/") { dir = String(dir.dropLast()) }
        return dir
    }
}

/// Toggle `dir` in a skip list. Covered by an entry (see `pathIsUnder`) →
/// every covering entry is removed, so previews come back for that entry's
/// whole subtree — deliberately: one toggle deep inside a skipped mount
/// visibly undoes the skip instead of silently fighting an ancestor entry.
/// Not covered → `dir` is appended. Returns the new list and whether `dir`
/// is now skipped. Pure.
public func toggleSkipDir(_ dir: String, in dirs: [String]) -> (dirs: [String], nowSkipped: Bool) {
    guard pathIsUnder(dir, anyOf: dirs) else { return (dirs + [dir], true) }
    return (dirs.filter { !pathIsUnder(dir, anyOf: [$0]) }, false)
}

/// Whether `path` is one of `dirs` or lies below one of them. Matches on
/// path-component boundaries — "/Volumes/ceph" covers "/Volumes/ceph/x" but
/// not "/Volumes/cephalon". Expects `dirs` without trailing slashes (what
/// `parseDirList` produces); "/" covers everything. Pure, no filesystem.
public func pathIsUnder(_ path: String, anyOf dirs: [String]) -> Bool {
    for dir in dirs {
        if path == dir { return true }
        if path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/") { return true }
    }
    return false
}
