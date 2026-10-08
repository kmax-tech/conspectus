import Foundation

// Yazi's yank buffer, mirrored into the app. The bundled plugin subscribes to
// yazi's `yank` DDS event and writes `@YANK:<copy|cut>:<path>\t<path>…` to the
// preview FIFO; the shell parses that here and shows the buffer in the
// shortcut bar. Yazi's own green/red count badge says only HOW MANY — once you
// navigate away from the source directory, nothing in yazi says WHAT is in
// the buffer. The bar line is that missing answer.

/// What yazi holds for the next paste: the yanked paths and whether they were
/// cut (`x`, paste moves) or copied (`y`, paste copies).
public struct YankState: Equatable {
    public let isCut: Bool
    public let paths: [String]

    public init(isCut: Bool, paths: [String]) {
        self.isCut = isCut
        self.paths = paths
    }
}

/// Parse the body of a `@YANK:` FIFO message (everything after the prefix):
/// `<copy|cut>:<path>\t<path>…`. An empty path list is a cleared buffer
/// (`Y`/`X`, or a paste after cut) and parses to a state with no paths.
/// Returns nil for a malformed mode — the caller warns, never guesses.
public func parseYankMessage(_ body: String) -> YankState? {
    guard let colon = body.firstIndex(of: ":") else { return nil }
    let isCut: Bool
    switch body[..<colon] {
    case "cut": isCut = true
    case "copy": isCut = false
    default: return nil
    }
    let rest = body[body.index(after: colon)...]
    let paths = rest.split(separator: "\t").map(String.init)
    return YankState(isCut: isCut, paths: paths)
}

/// Parse the body of a `@SELECTED:` FIFO message: tab-joined absolute paths,
/// yazi's per-tab selection at the moment ⌘L asked for it (pull, not push —
/// yazi publishes no event for selection changes, so the app requests a
/// snapshot over the DDS and the plugin answers with this). Empty body =
/// nothing selected.
public func parseSelectedPaths(_ body: String) -> [String] {
    body.split(separator: "\t").map(String.init)
}

/// The shortcut-bar text for a yank buffer: `"1 copied · main.lua"`,
/// `"3 cut · a.txt +2"` — count and mode, plus the first file's name so the
/// buffer is identifiable, not just countable. Nil for an empty buffer (the
/// bar then shows the tip of the day again).
public func yankHintSummary(_ state: YankState) -> String? {
    guard let first = state.paths.first else { return nil }
    let verb = state.isCut ? "cut" : "copied"
    // Last path segment; a path with no segments ("/") falls back to itself.
    let name = first.split(separator: "/").last.map(String.init) ?? first
    let more = state.paths.count > 1 ? " +\(state.paths.count - 1)" : ""
    return "\(state.paths.count) \(verb) · \(name)\(more)"
}
