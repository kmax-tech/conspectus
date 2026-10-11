import Foundation

// AppleScript sources the shell runs for the two things AppKit has no API
// for: Finder's Get Info window and Alfred's Universal Actions panel. Built
// here so the quoting is testable — a path with a quote or a backslash must
// survive into the script as the same path.

/// Alfred's bundle identifier (the `tell application id` target — stable
/// across Alfred 4/5, unlike the app name).
public let alfredBundleID = "com.runningwithcrayons.Alfred"

/// `s` as an AppleScript string literal: backslashes and double quotes
/// escaped, wrapped in double quotes.
public func appleScriptLiteral(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Open Alfred's Universal Actions panel for `paths` (Alfred's AppleScript
/// `action` command, item type `file`). `paths` must be non-empty — an empty
/// list is a caller bug, not a script.
public func alfredActionsScript(paths: [String]) -> String {
    precondition(!paths.isEmpty, "alfredActionsScript: no paths")
    let list = paths.map(appleScriptLiteral).joined(separator: ", ")
    return "tell application id \(appleScriptLiteral(alfredBundleID)) to action {\(list)} as type \"file\""
}

/// Open Finder's Get Info window for `path` and bring Finder forward.
public func finderGetInfoScript(path: String) -> String {
    """
    tell application "Finder"
        activate
        open information window of (POSIX file \(appleScriptLiteral(path)) as alias)
    end tell
    """
}
