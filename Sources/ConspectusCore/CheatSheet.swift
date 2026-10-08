import Foundation

// The ⌘K cheat sheet as data plus its filter. Rendering — fonts, palette, the
// floating panel — stays in the AppKit shell; what is testable is which lines
// a query keeps. The sheet lists everything, so without a filter the only way
// to find "indago" is to read all of it.

/// One line of the cheat sheet. An empty `key` marks a continuation line: it
/// belongs to the entry above it and is never shown on its own.
public struct CheatSheetEntry: Equatable {
    public let key: String
    public let desc: String

    public init(_ key: String, _ desc: String) {
        self.key = key
        self.desc = desc
    }
}

/// A titled block of cheat-sheet lines ("Navigate", "conspectus", …).
public struct CheatSheetGroup: Equatable {
    public let title: String
    public let entries: [CheatSheetEntry]

    public init(_ title: String, _ entries: [CheatSheetEntry]) {
        self.title = title
        self.entries = entries
    }

    /// Convenience for the literal tables in the shell: `("key", "desc")` pairs.
    public init(_ title: String, _ entries: [(String, String)]) {
        self.init(title, entries.map { CheatSheetEntry($0.0, $0.1) })
    }
}

/// Keep only the cheat-sheet lines that match `query`.
///
/// A match is a case- and diacritic-insensitive substring of a line's
/// `"<key>  <desc>"`. Continuation lines are matched and kept together with
/// the entry they explain, so a hit never shows half an explanation. A group
/// whose *title* matches is kept whole (query "clipboard" → the whole
/// Clipboard block). An empty query returns `groups` unchanged; groups that
/// end up without entries drop out.
public func filterCheatSheet(_ groups: [CheatSheetGroup], query: String) -> [CheatSheetGroup] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return groups }
    return groups.compactMap { group in
        if cheatSheetMatches(group.title, needle) { return group }
        let kept = cheatSheetBlocks(group.entries)
            .filter { block in block.contains { cheatSheetMatches($0.key + "  " + $0.desc, needle) } }
            .flatMap { $0 }
        return kept.isEmpty ? nil : CheatSheetGroup(group.title, kept)
    }
}

/// Split entries into blocks: one keyed entry plus the continuation lines
/// under it. Leading continuation lines (no keyed entry yet) form their own
/// block, so nothing is silently dropped.
public func cheatSheetBlocks(_ entries: [CheatSheetEntry]) -> [[CheatSheetEntry]] {
    var blocks: [[CheatSheetEntry]] = []
    for entry in entries {
        if entry.key.isEmpty, !blocks.isEmpty {
            blocks[blocks.count - 1].append(entry)
        } else {
            blocks.append([entry])
        }
    }
    return blocks
}

/// How many real shortcuts (keyed lines) the groups hold — the "12 of 240"
/// count in the panel footer.
public func cheatSheetShortcutCount(_ groups: [CheatSheetGroup]) -> Int {
    groups.reduce(0) { $0 + $1.entries.filter { !$0.key.isEmpty }.count }
}

/// Substring test used by the filter: case- and diacritic-insensitive, so
/// "cd" finds "cd there" and "ubersicht" would find "Übersicht".
public func cheatSheetMatches(_ haystack: String, _ needle: String) -> Bool {
    haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

/// Drop the built-in lines for keys the user has rebound in keymap.toml.
///
/// The user's own bindings are listed in their own group on top, so a default
/// line for the same key is at best a duplicate ("g i" twice) and at worst a
/// lie (`s` is the fzf picker only until the user rebinds it). Entries that
/// list alternatives ("o / Enter") go only when *every* alternative is bound,
/// so a half-rebound pair keeps its explanation. Continuation lines leave with
/// the entry they belong to; groups left empty drop out.
public func dropShadowedEntries(_ groups: [CheatSheetGroup],
                                boundBy bindings: [KeymapBinding]) -> [CheatSheetGroup] {
    let bound = Set(bindings.map { normalizedKeySequence($0.keys) })
    guard !bound.isEmpty else { return groups }
    return groups.compactMap { group in
        let kept = cheatSheetBlocks(group.entries)
            .filter { block in !isShadowed(block[0].key, by: bound) }
            .flatMap { $0 }
        return kept.isEmpty ? nil : CheatSheetGroup(group.title, kept)
    }
}

/// True when every alternative spelled out in a cheat-sheet key column
/// ("o / Enter" → "o", "Enter") is bound by the user.
private func isShadowed(_ displayKey: String, by bound: Set<String>) -> Bool {
    let alternatives = displayKey.components(separatedBy: "/")
        .map { $0.split(separator: " ").map(String.init) }
        .filter { !$0.isEmpty }
    guard !alternatives.isEmpty else { return false }
    return alternatives.allSatisfy { bound.contains(normalizedKeySequence($0)) }
}

/// Bring a key sequence into one comparable spelling, so yazi notation and the
/// cheat sheet's display spelling meet: `["<Enter>"]` and `["Enter"]` both
/// become "enter", `["→"]` becomes "right". Single characters keep their case
/// — in yazi `s` and `S` are different keys.
public func normalizedKeySequence(_ keys: [String]) -> String {
    keys.map(normalizedKeyToken).joined(separator: " ")
}

private func normalizedKeyToken(_ token: String) -> String {
    switch token {
    case "←": return "left"
    case "→": return "right"
    case "↑": return "up"
    case "↓": return "down"
    case "⏎": return "enter"
    default: break
    }
    var t = token
    if t.hasPrefix("<"), t.hasSuffix(">"), t.count > 2 {
        t = String(t.dropFirst().dropLast())
    }
    // Named keys ("Enter", "Space") are case-insensitive; single characters
    // are not — `s` and `S` are two bindings.
    return t.count > 1 ? t.lowercased() : t
}
