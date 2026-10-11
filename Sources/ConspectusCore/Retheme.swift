import Foundation

// Theme reload of the yazi panes (after a light↔dark switch, or ⌘R). yazi
// picks its Catppuccin flavor only at startup, so the app relaunches each
// pane — but only once the pane is idle. The bundled plugin refuses while the
// pane is in use and names the reason; the app keeps asking and the shortcut
// bar says what it is waiting for. This file holds the pure part of that
// line; the state machine lives in the shell (Panel+Terminal).

/// Reason words the plugin sends in `@RESTART_REFUSED:<peer>:<reason>`.
/// `tasks`/`selection` are transient (the app retries); `error` is final
/// for that pane (the plugin could not read yazi's state).
public let rethemeRefusalTasks = "tasks"
public let rethemeRefusalSelection = "selection"
public let rethemeRefusalError = "error"

/// Shortcut-bar line while yazi panes are owed a theme restart. `refusals`
/// maps a pending pane ("L"/"R") to the reason word of its last refusal; a
/// pane without an entry has not answered yet. An unknown reason word is
/// shown verbatim rather than dropped, so a plugin drift stays visible.
public func rethemeWaitSummary(pending: Set<String>, refusals: [String: String]) -> String {
    let reasons = Set(pending.compactMap { refusals[$0] })
    var waits: [String] = []
    if reasons.contains(rethemeRefusalTasks) { waits.append("file tasks") }
    if reasons.contains(rethemeRefusalSelection) { waits.append("the selection to clear") }
    waits += reasons.subtracting([rethemeRefusalTasks, rethemeRefusalSelection]).sorted()
    if waits.isEmpty { return "re-theming yazi…" }
    return "yazi re-theme waits for " + waits.joined(separator: " and ")
}
