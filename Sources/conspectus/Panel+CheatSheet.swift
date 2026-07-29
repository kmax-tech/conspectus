import Cocoa
import ConspectusCore

// Learning aids: the bottom shortcut bar content and the ⌘K cheat-sheet
// panel (the native, scrollable version of yazi's `~` help).

// Bottom shortcut bar: training wheels until the muscle memory sits.
// Toggled with ⌘/ ; visibility persists across launches (UserDefaults).
let hintBarHeight: CGFloat = 26
let showHintsKey = "ConspectusShowHints"

// The most-used yazi keys (defaults) plus conspectus's own shortcuts.
// y→p means: y (yank), then p (paste) — across panes in split mode too.
// cc/cf are yazi's copy-to-clipboard submenu (path / filename).
let shortcutHints: [(key: String, label: String)] = [
    ("y→p", "copy"), ("x→p", "move"), ("d", "trash"), ("r", "rename"),
    ("a", "new"), ("cc", "path"), ("cf", "name"), ("␣", "select"),
    ("/", "find"),
    ("⌘D", "split"), ("⌘E", "preview"), ("⌘J", "terminal"), ("⌘K", "all keys"), ("⌘/", "bar"),
]

// Full cheat sheet (⌘K): yazi's default mgr keymap, grouped, plus the
// conspectus keys. The user's own keymap.toml is parsed on every open
// (ConspectusCore.parseYaziKeymap) and shown as its own group on top;
// parse problems appear in the panel footer instead of being swallowed.
let cheatSheetGroups: [(title: String, entries: [(String, String)])] = [
    ("Navigate", [("h / ←", "parent directory"), ("l / →", "enter / open"),
                  ("j / k", "down / up"), ("Ctrl d / u", "half page down / up"),
                  ("Ctrl f / b", "full page down / up"),
                  ("g g", "to top"), ("G", "to bottom"),
                  ("H / L", "history back / forward"), ("z", "jump (zoxide)"), ("Z", "jump (fzf)")]),
    ("Select", [("Space", "toggle + move down"), ("v", "visual mode"),
                ("Esc", "clear selection"), ("Ctrl a", "select all")]),
    ("Files", [("o / Enter", "open"), ("O", "open with …"),
               ("y", "yank (copy)"), ("x", "cut"), ("p", "paste"), ("P", "paste (overwrite)"),
               ("Y / X", "cancel yank"), ("d", "trash"), ("D", "delete permanently"),
               ("a", "create (end with / = dir; a/b/c.txt makes parents)"),
               ("r", "rename"), (".", "toggle hidden")]),
    ("Clipboard", [("c c", "copy full path"), ("c d", "copy dirname"),
                   ("c f", "copy filename"), ("c n", "copy name w/o extension")]),
    ("Find", [("/", "find"), ("n / N", "next / previous match"), ("f", "filter"),
              ("s / S", "fzf picker: file names / contents (fdi/rgi)"),
              ("g s / g S", "stock search: results fill the pane (fd/rg)"),
              ("g i", "indago: indexed corpus search")]),
    ("Tabs", [("t", "new tab"), ("1…9", "switch tab"), ("[ / ]", "previous / next tab")]),
    ("Misc", [("w", "task manager"), (",", "sort menu"), ("~", "yazi help"), ("q", "quit")]),
    ("conspectus", [("⌘D", "toggle split pane"), ("⌘E", "toggle preview pane"),
                    ("⌘P", "pin preview to file (hold it while you edit; yellow border)"),
                    ("⌘I", "toggle nvim editor pane (IDE: yazi | nvim | preview)"),
                    ("⌘J", "terminal panel (opens in yazi's dir)"),
                    ("⌘W", "close terminal panel"),
                    ("⌘/", "toggle shortcut bar"), ("⌘K", "this cheat sheet"),
                    ("⌥← → / ⌥[ ]", "cycle pane focus (→ into preview: arrows page/scroll)"),
                    ("⌘⌃← / ⌘⌃→", "resize: narrow / widen the focused pane (WezTerm-style)"),
                    ("l / →", "on a file: focus the preview (h / ← there returns to yazi)"),
                    ("click", "focus the clicked pane (border follows)"),
                    ("drag + ⌘C", "select & copy text in the focused preview (PDF or text/markdown); ⌘A all"),
                    ("", "PDF preview focused: J/] next  K/[ prev  +/- zoom  s single↔continuous  n note"),
                    ("n / 📝 / ⌘N", "open + PIN the PDF's note in nvim — created next to the PDF if missing"),
                    ("", "ide mode: hovering a PDF auto-opens its existing note in nvim;"),
                    ("", "  cycling on closes it again unless pinned / edited / visible"),
                    ("", "  pinned notes: ★ in the bufferline, pin icon in the PDF bar;"),
                    ("", "  :ConspectusPin / :ConspectusUnpin (or :bd) toggle the pin in nvim"),
                    ("M", "toggle markdown render↔source (any yazi pane or the preview)"),
                    ("", "text preview focused: j/k scroll"),
                    ("o / Enter", "ide mode: send file(s) to the middle nvim (l/→ = peek in preview)"),
                    ("⌥arrows in nvim", "move nvim's own splits first, hand off to the neighbour pane at the edge"),
                    ("", "editor focused: the preview follows nvim's active file (⌘P still pins)"),
                    ("⌥↑ ↓", "pane area ⇄ terminal panel"),
                    ("=", "sync cd to other pane")]),
]

extension Panel {
    /// Toggle the floating cheat-sheet panel (full grouped key list — the
    /// native, scrollable version of yazi's `~` help).
    @objc func toggleCheatSheet() {
        if let p = cheatPanel, p.isVisible { p.orderOut(nil); return }
        if cheatPanel == nil { buildCheatSheet() }
        styleCheatSheet()
        cheatPanel?.orderFront(nil)   // KeylessPanel: never takes the keyboard
    }

    /// Build the floating panel holding the cheat sheet; frame persists
    /// across launches.
    func buildCheatSheet() {
        let panel = KeylessPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 660),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Shortcuts"
        panel.isFloatingPanel = true
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        panel.contentView = scroll
        if !panel.setFrameUsingName("ConspectusCheatSheet") { panel.center() }
        panel.setFrameAutosaveName("ConspectusCheatSheet")
        cheatPanel = panel
        cheatText = tv
    }

    /// Read the user's yazi keymap for the cheat sheet. Returns the bindings
    /// plus a status line for the panel footer — a missing file is normal
    /// (defaults only), a parse failure is reported there, never swallowed.
    func loadUserKeymap() -> (bindings: [KeymapBinding], status: String) {
        let configHome = ProcessInfo.processInfo.environment["YAZI_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/yazi")
        let path = (configHome as NSString).appendingPathComponent("keymap.toml")
        guard FileManager.default.fileExists(atPath: path) else {
            return ([], "no keymap.toml found — yazi defaults only")
        }
        do {
            let toml = try String(contentsOfFile: path, encoding: .utf8)
            let bindings: [KeymapBinding]
            do {
                bindings = try parseYaziKeymap(toml)
            } catch KeymapParseError.missingSection {
                bindings = try parseYaziKeymap(toml, section: "manager")   // pre-25.x name
            }
            return (bindings, "yazi defaults + \(bindings.count) bindings from your keymap.toml")
        } catch {
            return ([], "keymap.toml not parsed (\(error)) — yazi defaults only")
        }
    }

    /// (Re-)render the cheat sheet in the active palette; called on open and
    /// whenever the system appearance changes. Re-reads keymap.toml each time
    /// so config edits show up on the next ⌘K.
    func styleCheatSheet() {
        guard let tv = cheatText else { return }
        let pal = activePalette()
        tv.drawsBackground = true
        tv.backgroundColor = nsColor(pal.bg)
        tv.enclosingScrollView?.drawsBackground = true
        tv.enclosingScrollView?.backgroundColor = nsColor(pal.bg)
        let font = terminalFont(size: 12)
        let headColor = nsColor(pal.ansi[4])   // blue group headers
        let keyColor = nsColor(pal.ansi[3])    // yellow keys
        let fg = nsColor(pal.fg)
        let user = loadUserKeymap()
        var groups = cheatSheetGroups
        if !user.bindings.isEmpty {
            groups.insert(("Your keymap.toml",
                           user.bindings.map { ($0.keys.joined(separator: " "), $0.desc) }), at: 0)
        }
        let s = NSMutableAttributedString()
        for (gi, group) in groups.enumerated() {
            if gi > 0 { s.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            s.append(NSAttributedString(string: group.title + "\n",
                                        attributes: [.font: font, .foregroundColor: headColor]))
            for (key, desc) in group.entries {
                let padded = key.count < 12
                    ? key + String(repeating: " ", count: 12 - key.count)
                    : key + "  "
                s.append(NSAttributedString(string: "  " + padded,
                                            attributes: [.font: font, .foregroundColor: keyColor]))
                s.append(NSAttributedString(string: desc + "\n",
                                            attributes: [.font: font, .foregroundColor: fg]))
            }
        }
        s.append(NSAttributedString(
            string: "\n" + user.status,
            attributes: [.font: terminalFont(size: 10), .foregroundColor: fg.withAlphaComponent(0.6)]))
        tv.textStorage?.setAttributedString(s)
    }
}
