import Foundation

// Tip of the day: one keybinding trick per calendar day, surfaced in the
// shortcut bar (short form) and at the top of the ⌘K cheat sheet (long form).
// The cheat sheet lists *everything* — that is exactly why nothing in it gets
// read. A single rotating tip is the part that does.

/// One tip: the keys, a bar-sized label, and a sentence for the cheat sheet.
public struct Tip: Equatable {
    /// The keys as typed, e.g. `", s"` or `"⌘P"`.
    public let keys: String
    /// Two or three words for the shortcut bar.
    public let short: String
    /// One sentence for the cheat-sheet header — says *why*, not just what.
    public let long: String

    public init(keys: String, short: String, long: String) {
        self.keys = keys
        self.short = short
        self.long = long
    }
}

/// The curated pool. Everything here is either a yazi default binding or a
/// conspectus key — both also listed in the full cheat sheet, so a tip is
/// always something the user can look up again.
public let conspectusTips: [Tip] = [
    Tip(keys: ", s", short: "folder sizes",
        long: "Sort by size — the only mode in which yazi computes real directory sizes; "
            + "otherwise the number beside a folder is its entry count, not its bytes. "
            + "`, S` reverses, `, n` returns to the natural order."),
    Tip(keys: ", m", short: "sort by date",
        long: "Sort by modification time, `, M` newest last; `, b` sorts by birth time. "
            + "The sort is per session — `, n` restores the configured default."),
    Tip(keys: "m m", short: "date column",
        long: "Line mode: `m m` puts the modification time in the right-hand column, "
            + "`m s` the size, `m p` permissions, `m o` the owner, `m n` nothing."),
    Tip(keys: "Tab", short: "spot a file",
        long: "Spot the hovered entry: size, timestamps, permissions and owner in one "
            + "popup — without opening it or leaving the listing."),
    Tip(keys: "c d", short: "copy the dirname",
        long: "Clipboard submenu: `c c` full path, `c d` the directory, `c f` the file "
            + "name, `c n` the name without extension."),
    Tip(keys: "a", short: "create a path",
        long: "`a` creates: end the name with `/` for a directory, and `a/b/c.txt` "
            + "creates the parent directories on the way."),
    Tip(keys: "v", short: "visual select",
        long: "Visual mode selects a range as you move, Space toggles a single entry, "
            + "Esc clears the selection again."),
    Tip(keys: "f", short: "filter the listing",
        long: "`f` filters the listing down as you type; `/` seeks to matches instead. "
            + "Filter narrows, find jumps."),
    Tip(keys: "w", short: "task manager",
        long: "The task manager shows what yazi is still doing in the background — "
            + "size calculations, copies, deletions — and why a yazi re-theme may wait."),
    Tip(keys: "H / L", short: "history back",
        long: "History back and forward, like a browser; `z` jumps by frecency (zoxide) "
            + "and `Z` picks from the same database with fzf."),
    Tip(keys: "⌘P", short: "pin the preview",
        long: "Pin the preview to the current file (yellow border) so it stays put while "
            + "the cursor moves on — the way to read a PDF and browse at once."),
    Tip(keys: "⌘R", short: "re-theme panes",
        long: "Restart the yazi panes in place with the current theme — automatic after a "
            + "light↔dark switch, ⌘R forces it. Tabs survive it; it waits while file tasks "
            + "run or files are selected (the bar says which)."),
    Tip(keys: "=", short: "sync the panes",
        long: "`=` cd's the other pane to this one's directory — the quickest start for "
            + "a copy between two trees."),
    Tip(keys: "⌥← →", short: "cycle panes",
        long: "Cycle keyboard focus across the panes; moving right into the preview turns "
            + "the arrow keys into page/scroll for it."),
    Tip(keys: "M", short: "markdown source",
        long: "Toggle a markdown file between the typeset rendering and its source — in "
            + "a yazi pane or in the focused preview."),
]

/// The tip for a given day. Deterministic: the same calendar day always yields
/// the same tip, consecutive days step through the pool and wrap around.
/// Returns nil for an empty pool (nothing to show — the caller omits the tip).
public func tipOfTheDay(on date: Date,
                        from tips: [Tip] = conspectusTips,
                        calendar: Calendar = .current) -> Tip? {
    guard !tips.isEmpty else { return nil }
    // Swift's % keeps the dividend's sign; pre-epoch dates would index out of
    // bounds, so wrap negatives back into range.
    let i = dayNumber(of: date, calendar: calendar) % tips.count
    return tips[i < 0 ? i + tips.count : i]
}

/// Days between the Unix epoch and `date`, counted in the calendar's own time
/// zone, so the tip flips at local midnight rather than at some hour of the
/// morning. Negative for dates before 1970.
func dayNumber(of date: Date, calendar: Calendar) -> Int {
    let epoch = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
    let day = calendar.startOfDay(for: date)
    return calendar.dateComponents([.day], from: epoch, to: day).day ?? 0
}
