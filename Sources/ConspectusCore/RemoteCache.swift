import Foundation
import CryptoKit

// The on-disk cache both server checks share — CVS (`cvs -n -q update -l`
// per directory) and git (`git fetch` per repository): one file per key
// path under a cache dir, named by a hash of the path, starting with the
// path itself so a collision is detected, not trusted. The result formats
// differ (`CVSRemoteResult`, `GitRemoteResult`); the plumbing is one home.

/// Cache file for `dir`'s server check: named by a hash of the path (paths
/// are long and hold `/`); the file itself starts with the path so it stays
/// inspectable.
public func remoteCachePath(for dir: String, cacheDir: String) -> String {
    let digest = SHA256.hash(data: Data(dir.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    return (cacheDir as NSString).appendingPathComponent(digest)
}

/// The cached text for `dir` (everything after the `dir\t<path>` header
/// line); nil when there is no cache file, it is unreadable, or its header
/// names another path (hash collision, hand-edited file) — all treated as
/// "no check yet". Side effects: reads the cache file.
public func readRemoteCacheText(for dir: String, cacheDir: String) -> String? {
    let path = remoteCachePath(for: dir, cacheDir: cacheDir)
    // Deliberate try?: no cache yet is the normal case.
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    guard let nl = text.firstIndex(of: "\n"), text[..<nl] == "dir\t" + dir else { return nil }
    return String(text[text.index(after: nl)...])
}

/// Write `text` as `dir`'s cached check, under the `dir\t<path>` header.
/// Throws on an unwritable cache dir — the caller reports it. Side effects:
/// creates `cacheDir`, writes the file.
public func writeRemoteCacheText(_ text: String, for dir: String, cacheDir: String) throws {
    try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    try ("dir\t" + dir + "\n" + text)
        .write(toFile: remoteCachePath(for: dir, cacheDir: cacheDir), atomically: true, encoding: .utf8)
}

/// Still worth showing at `now`: a good check (`error` nil) within `ttl`, a
/// failed one within `errorTTL` (short — the server may be back).
public func remoteCheckIsFresh(checked: Date, error: String?, now: Date, ttl: TimeInterval,
                               errorTTL: TimeInterval) -> Bool {
    now.timeIntervalSince(checked) < (error == nil ? ttl : errorTTL)
}

/// When a check happened, in the listing's date words minus its column
/// padding: `today 09:05`, `y-day 16:01`, `16.10. 14:32`, `15.01. 2024`.
public func remoteCheckAge(_ checked: Date, now: Date, timeZone: TimeZone) -> String {
    listingDate(checked, now: now, timeZone: timeZone)
        .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
}
