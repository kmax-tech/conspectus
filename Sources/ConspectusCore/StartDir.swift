import Foundation

// Start-directory resolution: explicit [path] arg, else the remembered last
// cwd (yazi writes it on exit via --cwd-file), else $HOME.

/// True if `path` exists and is a directory.
public func isDirectory(_ path: String) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
}

/// The resolved start directory, plus an optional warning when an explicit
/// argument had to be discarded — the fallback stays visible to the caller
/// instead of happening silently.
public struct StartDir: Equatable {
    public let path: String
    /// Set when the user gave a path that is not a directory and we fell back.
    public let warning: String?

    public init(path: String, warning: String? = nil) {
        self.path = path
        self.warning = warning
    }
}

/// Resolve the directory the file manager should start in.
///
/// Precedence: an explicit `raw` argument (tilde and relative paths resolved),
/// else the directory remembered in `lastCwdFile`, else `home`.
///
/// - Parameters:
///   - raw: The [path] CLI argument, or nil/empty if none was given.
///   - lastCwdFile: File holding the last cwd (absent on first run — that is
///     the normal case, not an error, hence the deliberate `try?`).
///   - home: Final fallback, normally `$HOME`.
/// - Returns: The start directory; `warning` is non-nil iff an explicit `raw`
///   was given but is not an existing directory.
public func resolveStart(_ raw: String?, lastCwdFile: String,
                         home: String = NSHomeDirectory()) -> StartDir {
    guard let raw = raw, !raw.isEmpty else {
        if let saved = try? String(contentsOfFile: lastCwdFile, encoding: .utf8) {
            let p = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if isDirectory(p) { return StartDir(path: p) }
        }
        return StartDir(path: home)
    }
    var p = (raw as NSString).expandingTildeInPath
    if !p.hasPrefix("/") {
        p = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p)
    }
    p = (p as NSString).standardizingPath
    if isDirectory(p) { return StartDir(path: p) }
    return StartDir(path: home,
                    warning: "conspectus: '\(raw)' is not a directory — starting in \(home)")
}
