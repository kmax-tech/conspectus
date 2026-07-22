import Foundation

// Focused parser for the keymap subset of yazi's keymap.toml — enough to show
// the user's real bindings in the cheat sheet without pulling in a TOML
// dependency. Supported: the inline-table array style
// (`prepend_keymap = [ { on = ..., run = ..., desc = ... }, ... ]`) and the
// array-of-tables style (`[[mgr.prepend_keymap]]` blocks), including literal /
// basic / triple-quoted strings, comments, and tabs. It is NOT a general TOML
// parser; anything outside this subset fails loudly with a KeymapParseError.

/// One key binding from a yazi keymap.toml.
public struct KeymapBinding: Equatable {
    /// The key sequence in yazi notation, e.g. ["g", "p"] or ["<C-i>"].
    public let keys: [String]
    /// Human-readable description: the entry's `desc`, or its `run` compacted
    /// to one line when no `desc` is given.
    public let desc: String

    public init(keys: [String], desc: String) {
        self.keys = keys
        self.desc = desc
    }
}

/// Errors thrown by `parseYaziKeymap`.
public enum KeymapParseError: Error, Equatable, CustomStringConvertible {
    case missingSection(String)
    case entryWithoutOn(index: Int)
    case unterminatedString
    case unexpectedToken(near: String)

    public var description: String {
        switch self {
        case .missingSection(let s): return "section [\(s)] not found"
        case .entryWithoutOn(let i): return "keymap entry #\(i + 1) has no 'on' key"
        case .unterminatedString: return "unterminated string"
        case .unexpectedToken(let near): return "unexpected token near '\(near)'"
        }
    }
}

/// Parse the key bindings of one section (default: `mgr`) out of a yazi
/// keymap.toml. Collects `prepend_keymap`, `keymap`, and `append_keymap`
/// entries in file order.
///
/// - Parameters:
///   - toml: The raw file contents.
///   - section: The top-level section to read (`mgr`; older configs use
///     `manager` — callers can retry with that on `missingSection`).
/// - Returns: The bindings found (possibly empty if the section has none).
/// - Throws: `KeymapParseError` if the section is missing or an entry is
///   malformed — a broken config should be reported, not silently dropped.
public func parseYaziKeymap(_ toml: String, section: String = "mgr") throws -> [KeymapBinding] {
    var scanner = TomlKeymapScanner(toml)
    return try scanner.parse(section: section)
}

/// Character-level scanner implementing the subset described above.
private struct TomlKeymapScanner {
    private let s: [Character]
    private var i = 0
    private var bindings: [KeymapBinding] = []
    private var entryIndex = 0

    init(_ text: String) {
        s = Array(text)
    }

    // MARK: top level

    mutating func parse(section target: String) throws -> [KeymapBinding] {
        var current = ""
        var found = false
        while true {
            skipTrivia()
            guard i < s.count else { break }
            if s[i] == "[" {
                let (name, isArrayOfTables) = try parseHeader()
                current = name
                if name == target { found = true }
                if isArrayOfTables, isKeymapArray(name, target: target) {
                    found = true
                    let fields = try parseTableFields()
                    try appendBinding(fields)
                }
                continue
            }
            let key = parseBareKey()
            guard !key.isEmpty else { throw KeymapParseError.unexpectedToken(near: context()) }
            skipTrivia()
            try expect("=")
            skipTrivia()
            if current == target, isKeymapKey(key), i < s.count, s[i] == "[" {
                try parseInlineTableArray()
            } else {
                try skipValue()
            }
        }
        guard found else { throw KeymapParseError.missingSection(target) }
        return bindings
    }

    private func isKeymapKey(_ key: String) -> Bool {
        key == "prepend_keymap" || key == "keymap" || key == "append_keymap"
    }

    private func isKeymapArray(_ name: String, target: String) -> Bool {
        isKeymapKey(name.hasPrefix(target + ".") ? String(name.dropFirst(target.count + 1)) : "")
    }

    /// `[name]` or `[[name]]`; leaves the scanner after the closing bracket(s).
    private mutating func parseHeader() throws -> (name: String, isArrayOfTables: Bool) {
        try expect("[")
        var isArray = false
        if i < s.count, s[i] == "[" { isArray = true; i += 1 }
        var name = ""
        while i < s.count, s[i] != "]" { name.append(s[i]); i += 1 }
        try expect("]")
        if isArray { try expect("]") }
        return (name.trimmingCharacters(in: .whitespaces), isArray)
    }

    // MARK: entries

    /// Fields of a `[[...]]` table: `key = value` lines until the next header
    /// or end of file.
    private mutating func parseTableFields() throws -> [String: Field] {
        var fields: [String: Field] = [:]
        while true {
            skipTrivia()
            if i >= s.count || s[i] == "[" { return fields }
            try parseField(into: &fields)
        }
    }

    /// `{ key = value, ... }` inline table.
    private mutating func parseInlineTable() throws -> [String: Field] {
        try expect("{")
        var fields: [String: Field] = [:]
        while true {
            skipTrivia()
            guard i < s.count else { throw KeymapParseError.unexpectedToken(near: "end of file") }
            if s[i] == "}" { i += 1; return fields }
            if s[i] == "," { i += 1; continue }
            try parseField(into: &fields)
        }
    }

    /// `[ { ... }, { ... } ]` — the keymap array itself.
    private mutating func parseInlineTableArray() throws {
        try expect("[")
        while true {
            skipTrivia()
            guard i < s.count else { throw KeymapParseError.unexpectedToken(near: "end of file") }
            if s[i] == "]" { i += 1; return }
            if s[i] == "," { i += 1; continue }
            guard s[i] == "{" else { throw KeymapParseError.unexpectedToken(near: context()) }
            let fields = try parseInlineTable()
            try appendBinding(fields)
        }
    }

    private mutating func parseField(into fields: inout [String: Field]) throws {
        let key = parseBareKey()
        guard !key.isEmpty else { throw KeymapParseError.unexpectedToken(near: context()) }
        skipTrivia()
        try expect("=")
        skipTrivia()
        guard i < s.count else { throw KeymapParseError.unexpectedToken(near: "end of file") }
        if isStringDelimiter(s[i]) {
            fields[key] = .string(try parseString())
        } else if s[i] == "[", key == "on" {
            fields[key] = .array(try parseStringArray())
        } else {
            try skipValue()
        }
    }

    private mutating func appendBinding(_ fields: [String: Field]) throws {
        defer { entryIndex += 1 }
        let keys: [String]
        switch fields["on"] {
        case .string(let one): keys = [one]
        case .array(let many): keys = many
        case nil: throw KeymapParseError.entryWithoutOn(index: entryIndex)
        }
        let desc: String
        if case .string(let d)? = fields["desc"] {
            desc = d
        } else if case .string(let run)? = fields["run"] {
            desc = compactRun(run)
        } else {
            desc = ""
        }
        bindings.append(KeymapBinding(keys: keys, desc: desc))
    }

    private enum Field {
        case string(String)
        case array([String])
    }

    /// Collapse a multiline `run` command into one short display line.
    private func compactRun(_ run: String) -> String {
        let oneLine = run.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
    }

    // MARK: values

    /// `[ "a", "b" ]` — array of strings (the `on` key sequence).
    private mutating func parseStringArray() throws -> [String] {
        try expect("[")
        var out: [String] = []
        while true {
            skipTrivia()
            guard i < s.count else { throw KeymapParseError.unterminatedString }
            if s[i] == "]" { i += 1; return out }
            if s[i] == "," { i += 1; continue }
            out.append(try parseString())
        }
    }

    private func isStringDelimiter(_ c: Character) -> Bool { c == "\"" || c == "'" }

    /// Any TOML string: literal `'...'`, basic `"..."` (minimal escapes), or
    /// their triple-quoted multiline forms.
    private mutating func parseString() throws -> String {
        let quote = s[i]
        let triple = i + 2 < s.count && s[i + 1] == quote && s[i + 2] == quote
        i += triple ? 3 : 1
        var out = ""
        while i < s.count {
            if s[i] == quote, !triple {
                i += 1
                return out
            }
            if triple, s[i] == quote, i + 2 < s.count, s[i + 1] == quote, s[i + 2] == quote {
                i += 3
                // TOML: a newline right after the opening delimiter is trimmed.
                if out.first == "\n" { out.removeFirst() }
                return out
            }
            if quote == "\"", s[i] == "\\", i + 1 < s.count {
                i += 1
                switch s[i] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(s[i])
                }
                i += 1
                continue
            }
            out.append(s[i])
            i += 1
        }
        throw KeymapParseError.unterminatedString
    }

    /// Skip any value we don't care about, respecting strings and nesting.
    private mutating func skipValue() throws {
        guard i < s.count else { return }
        if isStringDelimiter(s[i]) { _ = try parseString(); return }
        if s[i] == "[" || s[i] == "{" {
            var depth = 0
            while i < s.count {
                if isStringDelimiter(s[i]) { _ = try parseString(); continue }
                if s[i] == "[" || s[i] == "{" { depth += 1 }
                if s[i] == "]" || s[i] == "}" {
                    depth -= 1
                    if depth == 0 { i += 1; return }
                }
                i += 1
            }
            throw KeymapParseError.unexpectedToken(near: "end of file")
        }
        // Bare scalar (number, bool, date): runs to the next separator.
        while i < s.count, s[i] != ",", s[i] != "\n", s[i] != "]", s[i] != "}" { i += 1 }
    }

    // MARK: low-level

    private mutating func parseBareKey() -> String {
        var out = ""
        while i < s.count, s[i].isLetter || s[i].isNumber || s[i] == "_" || s[i] == "-" {
            out.append(s[i])
            i += 1
        }
        return out
    }

    /// Skip whitespace, newlines, and `#` comments.
    private mutating func skipTrivia() {
        while i < s.count {
            if s[i].isWhitespace { i += 1; continue }
            if s[i] == "#" {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            return
        }
    }

    private mutating func expect(_ c: Character) throws {
        guard i < s.count, s[i] == c else { throw KeymapParseError.unexpectedToken(near: context()) }
        i += 1
    }

    private func context() -> String {
        String(s[i..<min(i + 24, s.count)])
    }
}
