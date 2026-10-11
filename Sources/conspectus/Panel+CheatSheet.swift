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
    ("/", "find"), ("w", "tasks"), ("⇥", "info"),
    ("⌘L", "selected"), ("⌘D", "split"), ("⌘E", "preview"), ("⌘J", "terminal"), ("⌘K", "all keys"), ("⌘/", "bar"),
]

// Full cheat sheet (⌘K): yazi's default mgr keymap, grouped, plus the
// conspectus keys. The user's own keymap.toml is parsed on every open
// (ConspectusCore.parseYaziKeymap) and shown as its own group on top;
// parse problems appear in the panel footer instead of being swallowed.
let cheatSheetGroups: [CheatSheetGroup] = [
    CheatSheetGroup("Navigate", [("h / ←", "parent directory"), ("l / →", "enter / open"),
                  ("j / k", "down / up"), ("Ctrl d / u", "half page down / up"),
                  ("Ctrl f / b", "full page down / up"),
                  ("g g", "to top"), ("G", "to bottom"),
                  ("H / L", "history back / forward"), ("z", "jump (zoxide)"), ("Z", "jump (fzf)")]),
    CheatSheetGroup("Select", [("Space", "toggle + move down"), ("v", "visual mode"),
                ("Esc", "clear selection"), ("Ctrl a", "select all")]),
    CheatSheetGroup("Files", [("o / Enter", "open"), ("O", "open with …"),
               ("y", "yank (copy)"), ("x", "cut"), ("p", "paste"), ("P", "paste (overwrite)"),
               ("", "copy = y here → go to the target dir → p (across split panes too)"),
               ("", "no selection? y/x act on the hovered file — Esc clears a stale one"),
               ("g f", "follow symlink (→ rows) to the real file — y there copies the"),
               ("", "  file itself; y on the link copies the link, whose relative"),
               ("", "  target may dangle at the new place"),
               ("- / _", "paste as symlink: absolute / relative  ·  Ctrl - hardlink"),
               ("Y / X", "cancel yank"), ("d", "trash"), ("D", "delete permanently"),
               ("a", "create (end with / = dir; a/b/c.txt makes parents)"),
               ("r", "rename"), (".", "toggle hidden")]),
    CheatSheetGroup("Clipboard", [("c c", "copy full path"), ("c d", "copy dirname"),
                   ("c f", "copy filename"), ("c n", "copy name w/o extension")]),
    CheatSheetGroup("Find", [("/", "find"), ("n / N", "next / previous match"), ("f", "filter"),
              ("s / S", "fzf picker: file names / contents (fdi/rgi)"),
              ("g s / g S", "stock search: results fill the pane (fd/rg)"),
              ("g i", "indago: indexed corpus search")]),
    CheatSheetGroup("Tabs", [("t", "new tab"), ("1…9", "switch tab"), ("[ / ]", "previous / next tab")]),
    CheatSheetGroup("Sort & inspect", [(", s / , S", "sort by size — the only mode that computes real directory sizes"),
                        (", m / , M", "sort by modified time (, b birth time)"),
                        (", n / , a / , e", "natural / alphabetical / extension order"),
                        ("m s / m m", "right-hand column: size / modified time"),
                        ("m p / m o / m n", "column: permissions / owner / none"),
                        ("Tab", "spot the hovered entry (size, times, permissions, owner)")]),
    CheatSheetGroup("Misc", [("w", "task manager"), ("~", "yazi help"), ("q", "quit")]),
    CheatSheetGroup("conspectus", [("⌘D", "toggle split pane"), ("⌘E", "toggle preview pane"),
                    ("⌘P", "pin preview to file (hold it while you edit; yellow border)"),
                    ("⌘⇧P", "preview off/on for the current folder + subtree (network mounts)"),
                    ("⌘I", "toggle nvim editor pane (IDE: yazi | nvim | preview)"),
                    ("⌘L", "yazi's selected files as a clickable list in the preview"),
                    ("", "  (the only cross-directory view — yazi highlights marks"),
                    ("", "  only inside their own directory; the yellow badge just counts)"),
                    ("⌘J", "terminal panel (opens in yazi's dir)"),
                    ("⌘R", "re-theme yazi panes now (automatic on light↔dark; waits while tasks or a selection exist)"),
                    ("", "yazi tabs survive ⌘R and app restarts (bare start restores; [path] = clean)"),
                    ("⌘W", "close terminal panel"),
                    ("⌘/", "toggle shortcut bar"),
                    ("⌘K", "this cheat sheet — type to filter it, Esc hands the keys back to yazi"),
                    ("⌥← → / ⌥[ ]", "cycle pane focus (→ into preview: arrows page/scroll)"),
                    ("⌘⌃← / ⌘⌃→", "resize: narrow / widen the focused pane (WezTerm-style)"),
                    ("l / →", "on a file: focus the preview (h / ← there returns to yazi)"),
                    ("click", "focus the clicked pane (border follows); on a folder row: enter it"),
                    ("right-click", "Finder's file menu for the item under the mouse: Open, Open With,"),
                    ("", "  Reveal/Get Info, Share, Services, copy path/name; Rename/Trash run in yazi"),
                    ("click path", "the cwd in the header is a breadcrumb — click a segment to"),
                    ("", "  cd there (the only mouse way UP; columns only descend)"),
                    ("⌘↑", "enclosing folder (Go menu) — one level up, like in Finder"),
                    ("⌥⌘R", "reveal in Finder (dir opens, file is selected) — VS Code's key;"),
                    ("", "  in a bare terminal yazi the same move is E f"),
                    ("⌥⌘P", "print the previewed file (File menu) — macOS print dialog;"),
                    ("", "  PDF page-for-page, image to a page, source/markdown paginated"),
                    ("⌘⇧[ / ⌘⇧]", "previous / next yazi tab (the kitty/WezTerm tab chord)"),
                    ("⌘1…⌘9", "jump to that tab — both work from nvim, preview and the"),
                    ("", "  terminal panel, where yazi's own [ / ] / 1…9 never arrive"),
                    ("mouse 4 / 5", "back / forward in that pane's directory history"),
                    ("⌘[ / ⌘]", "back / forward (Go menu — same as the mouse side buttons)"),
                    ("drag + ⌘C", "select & copy text in the focused preview (PDF or text/markdown); ⌘A all"),
                    ("", "PDF preview focused: J/] next  K/[ prev  +/- zoom  s single↔continuous  n note"),
                    ("n / 📝 / ⌘N", "open + PIN the PDF's note in nvim (toggle: unpins if already pinned)"),
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
    /// native, scrollable version of yazi's `~` help). Opening puts the
    /// keyboard in its filter field: a sheet is opened to look something up.
    /// Closing (and Esc) hands the keys back to yazi.
    ///
    /// Side effects: shows/hides the panel, moves key window focus.
    @objc func toggleCheatSheet() {
        if let p = cheatPanel, p.isVisible { closeCheatSheet(); return }
        if cheatPanel == nil { buildCheatSheet() }
        cheatSearch?.stringValue = ""
        styleCheatSheet()
        cheatPanel?.makeKeyAndOrderFront(nil)
        if let field = cheatSearch { cheatPanel?.makeFirstResponder(field) }
    }

    /// Hide the sheet and return the keyboard to the window — a still-key
    /// panel would silently swallow the next yazi keystrokes.
    func closeCheatSheet() {
        cheatPanel?.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Build the floating panel holding the cheat sheet: filter field on top,
    /// the scrollable key list below. Frame persists across launches.
    func buildCheatSheet() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 660),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Shortcuts"
        panel.isFloatingPanel = true
        // Only the filter field takes the keyboard: clicking the list or the
        // scroller leaves yazi key, the way this panel always behaved.
        panel.becomesKeyOnlyIfNeeded = true

        let content = NSView(frame: panel.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        let pad: CGFloat = 8, fieldH: CGFloat = 24
        let search = NSSearchField(frame: NSRect(x: pad, y: content.bounds.height - fieldH - pad,
                                                 width: content.bounds.width - 2 * pad, height: fieldH))
        search.autoresizingMask = [.width, .minYMargin]
        search.placeholderString = "Filter keys and descriptions (Esc: clear + back to yazi)"
        search.font = terminalFont(size: 12)
        search.delegate = self   // controlTextDidChange filters on every keystroke

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: content.bounds.width,
                                                height: content.bounds.height - fieldH - 2 * pad))
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
        content.addSubview(search)
        content.addSubview(scroll)
        panel.contentView = content
        if !panel.setFrameUsingName("ConspectusCheatSheet") { panel.center() }
        panel.setFrameAutosaveName("ConspectusCheatSheet")
        cheatPanel = panel
        cheatText = tv
        cheatSearch = search
    }

    /// Live filtering: every keystroke re-renders the sheet.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as AnyObject?) === cheatSearch else { return }
        renderFilteredCheatSheet()
    }

    /// Esc in the filter field: clear the filter and give the keyboard back to
    /// yazi, with the sheet still open as a reference card.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === cheatSearch, selector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        cheatSearch?.stringValue = ""
        renderFilteredCheatSheet()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Re-render for the current filter and jump back to the top, so the first
    /// hit is the first thing on screen.
    func renderFilteredCheatSheet() {
        styleCheatSheet()
        cheatText?.enclosingScrollView?.documentView?.scroll(.zero)
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

    /// Put the day's tip at the top of the cheat sheet: the same tip the
    /// shortcut bar abbreviates, here with the sentence that says why it is
    /// worth knowing. Continuation lines hang under the text, not under the
    /// keys. Nothing is appended when the tip pool is empty.
    func appendTipOfTheDay(to s: NSMutableAttributedString, font: NSFont,
                           headColor: NSColor, keyColor: NSColor, fg: NSColor) {
        guard let tip = tipOfTheDay(on: Date()) else { return }
        let wrap = NSMutableParagraphStyle()
        wrap.headIndent = 4 * font.maximumAdvancement.width
        wrap.paragraphSpacing = font.pointSize
        s.append(NSAttributedString(string: "Tip of the day\n",
                                    attributes: [.font: font, .foregroundColor: headColor]))
        s.append(NSAttributedString(string: "  " + tip.keys + "  ",
                                    attributes: [.font: font, .foregroundColor: keyColor,
                                                 .paragraphStyle: wrap]))
        s.append(NSAttributedString(string: tip.long + "\n",
                                    attributes: [.font: font, .foregroundColor: fg,
                                                 .paragraphStyle: wrap]))
    }

    /// (Re-)render the cheat sheet in the active palette, filtered by whatever
    /// stands in the search field; called on open, on every keystroke there,
    /// and whenever the system appearance changes. Re-reads keymap.toml each
    /// time so config edits show up on the next ⌘K.
    func styleCheatSheet() {
        guard let tv = cheatText else { return }
        let query = (cheatSearch?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        // The user's keymap.toml wins: its group goes on top, and the yazi
        // defaults it rebinds drop out instead of contradicting it.
        var groups = dropShadowedEntries(cheatSheetGroups, boundBy: user.bindings)
        if !user.bindings.isEmpty {
            groups.insert(CheatSheetGroup("Your keymap.toml",
                                          user.bindings.map { ($0.keys.joined(separator: " "), $0.desc) }),
                          at: 0)
        }
        let total = cheatSheetShortcutCount(groups)
        groups = filterCheatSheet(groups, query: query)
        let s = NSMutableAttributedString()
        // While filtering, the sheet is a search result — the tip would only
        // push the hits off the top.
        if query.isEmpty {
            appendTipOfTheDay(to: s, font: font, headColor: headColor, keyColor: keyColor, fg: fg)
        }
        for (gi, group) in groups.enumerated() {
            if gi > 0 { s.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            s.append(NSAttributedString(string: group.title + "\n",
                                        attributes: [.font: font, .foregroundColor: headColor]))
            for entry in group.entries {
                let key = entry.key
                let padded = key.count < 12
                    ? key + String(repeating: " ", count: 12 - key.count)
                    : key + "  "
                s.append(NSAttributedString(string: "  " + padded,
                                            attributes: [.font: font, .foregroundColor: keyColor]))
                s.append(NSAttributedString(string: entry.desc + "\n",
                                            attributes: [.font: font, .foregroundColor: fg]))
            }
        }
        if !query.isEmpty {
            highlightMatches(of: query, in: s, color: nsColor(pal.ansi[3]).withAlphaComponent(0.30))
        }
        let footer = query.isEmpty
            ? user.status
            : "\(cheatSheetShortcutCount(groups)) of \(total) shortcuts match “\(query)”  ·  \(user.status)"
        s.append(NSAttributedString(
            string: "\n" + footer,
            attributes: [.font: terminalFont(size: 10), .foregroundColor: fg.withAlphaComponent(0.6)]))
        tv.textStorage?.setAttributedString(s)
    }

    /// Mark every occurrence of the query in the rendered sheet, so the hit is
    /// visible inside a line, not just the line inside the list.
    func highlightMatches(of query: String, in s: NSMutableAttributedString, color: NSColor) {
        let text = s.string as NSString
        var from = 0
        while from < text.length {
            let rest = NSRange(location: from, length: text.length - from)
            let hit = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: rest)
            guard hit.location != NSNotFound else { return }
            s.addAttribute(.backgroundColor, value: color, range: hit)
            from = hit.location + max(hit.length, 1)
        }
    }
}
