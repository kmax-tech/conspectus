import Cocoa
import ConspectusCore
import SwiftTerm

// Appearance: palette plumbing, fonts, and the folder-listing renderer.
// Follow the macOS system appearance: Catppuccin Latte in light mode, Mocha in
// dark. yazi picks its matching flavor by querying our background via OSC 11
// (SwiftTerm answers), so the whole panel stays one coherent theme.

func systemIsDark() -> Bool {
    // Read the LIVE effective appearance, not the AppleInterfaceStyle user
    // default: that default is frequently still stale when
    // AppleInterfaceThemeChangedNotification fires, so reading it there installed
    // the OLD palette on a dark<->light switch — and, because we advertise that
    // background to yazi over OSC 11, yazi then picked the wrong flavor too,
    // leaving a washed-out mismatch (e.g. Mocha's pale blue on Latte's light bg)
    // until the next relaunch. effectiveAppearance is current at that moment.
    NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
}

func activePalette() -> Palette { systemIsDark() ? mocha : latte }

/// bat theme matching the app's palette (Catppuccin Latte/Mocha, same as the
/// terminal + yazi), or the user's `BAT_THEME` if they set one. Both Catppuccin
/// bat themes ship with recent bat; a missing theme makes bat fall back to its
/// default, which is degraded but not broken.
func batTheme() -> String {
    if let t = ProcessInfo.processInfo.environment["BAT_THEME"], !t.isEmpty { return t }
    return systemIsDark() ? "Catppuccin Mocha" : "Catppuccin Latte"
}

/// Turn parsed ANSI runs (from `bat --color=always`) into an attributed string:
/// truecolor foreground per run, bold/italic via font traits, underline as an
/// attribute. `defaultFg` fills runs with no explicit colour; a run's ANSI
/// background is applied when set, otherwise the pane's themed bg shows through.
func renderANSI(_ runs: [AnsiRun], font: NSFont, defaultFg: NSColor) -> NSAttributedString {
    let fm = NSFontManager.shared
    let bold = fm.convert(font, toHaveTrait: .boldFontMask)
    let italic = fm.convert(font, toHaveTrait: .italicFontMask)
    let boldItalic = fm.convert(bold, toHaveTrait: .italicFontMask)
    let result = NSMutableAttributedString()
    func color(_ c: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
    for run in runs {
        let f = run.bold && run.italic ? boldItalic : run.bold ? bold : run.italic ? italic : font
        var attrs: [NSAttributedString.Key: Any] = [.font: f]
        attrs[.foregroundColor] = run.fg.map(color) ?? defaultFg
        if let bg = run.bg { attrs[.backgroundColor] = color(bg) }   // some bat themes set one
        if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        result.append(NSAttributedString(string: run.text, attributes: attrs))
    }
    return result
}


/// SwiftTerm color from a palette hex string (validated by Palette's init;
/// see nsColor in ConspectusCore for why try! is the honest choice here).
func stColor(_ hex: String) -> SwiftTerm.Color {
    let v = try! parseHexColor(hex)
    func chan(_ shift: UInt32) -> UInt16 { UInt16((v >> shift) & 0xff) * 257 }
    return SwiftTerm.Color(red: chan(16), green: chan(8), blue: chan(0))
}

func applyTheme(_ t: LocalProcessTerminalView) {
    let p = activePalette()
    t.installColors(p.ansi.map(stColor))
    t.nativeBackgroundColor = nsColor(p.bg)
    t.nativeForegroundColor = nsColor(p.fg)
    t.caretColor            = nsColor(p.cursor)
}

// A Nerd Font so yazi's icon glyphs render. Override with CONSPECTUS_FONT /
// CONSPECTUS_FONT_SIZE; falls back through installed Nerd Fonts, then plain mono.
// `size` overrides the configured size (used by the smaller shortcut bar).
func terminalFont(size overrideSize: Double? = nil) -> NSFont {
    let env = ProcessInfo.processInfo.environment
    let size = overrideSize ?? (Double(env["CONSPECTUS_FONT_SIZE"] ?? "") ?? 14)
    var names = ["JetBrainsMono Nerd Font Mono", "JetBrainsMono Nerd Font",
                 "Hack Nerd Font Mono", "MesloLGS NF"]
    if let override = env["CONSPECTUS_FONT"], !override.isEmpty { names.insert(override, at: 0) }
    for n in names {
        if let f = NSFont(name: n, size: size) { return f }
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

// Directory look-ahead for the right pane: Quick Look only shows a folder's
// icon + metadata, so for directories we render the contents ourselves —
// folders first, natural sort, Nerd Font glyphs, Catppuccin colors per type,
// modification date as a dimmed column behind the names.
// Loading (ConspectusCore.loadFolder: bulk isDirectory keys, sort, cap)
// happens off the main thread; only a screenful is rendered anyway, and
// "… and N more" makes the cut visible.
let folderListingCap = 500
/// Names longer than this (in characters) push their date past the shared
/// date column instead of widening it for every row.
let folderListingNameColumn = 40

/// Render loaded folder contents in the current theme. Does no I/O — safe to
/// build off the main thread; TextKit layout happens when the result is
/// applied to the text view on main. Every row carries a .link with its URL
/// (directory-flag set accordingly): clicking a folder navigates yazi there,
/// clicking a file previews it in the Quick Look pane.
func renderListing(_ contents: FolderContents, in dir: String) -> NSAttributedString {
    let pal = activePalette()
    let fg = nsColor(pal.fg), blue = nsColor(pal.ansi[4])
    let font = terminalFont()
    if let err = contents.error {
        // Folder vanished or lost permission mid-hover — show it in the pane
        // instead of a silently empty listing.
        return NSAttributedString(string: "  (unreadable: \(err))",
                                  attributes: [.font: font, .foregroundColor: fg])
    }
    if contents.entries.isEmpty {
        return NSAttributedString(string: "  (empty)", attributes: [.font: font, .foregroundColor: fg])
    }
    // Date column: one tab stop just past the longest (capped) row, measured
    // in the monospace font's advance — glyph + two spaces + name + "/".
    let longest = contents.entries.map { $0.name.count + ($0.isDir ? 1 : 0) }.max() ?? 0
    let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
    let para = NSMutableParagraphStyle()
    para.tabStops = [NSTextTab(textAlignment: .left,
                               location: CGFloat(3 + min(longest, folderListingNameColumn) + 3) * advance)]
    let dim = fg.withAlphaComponent(0.5)
    let now = Date()
    let out = NSMutableAttributedString()
    for e in contents.entries {
        let icon = e.isDir ? FileIcon(glyph: "\u{f07b}", color: blue)   // nf-fa-folder for dirs
                           : fileIcon(e.name, pal)
        let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(e.name),
                      isDirectory: e.isDir)
        let attrs: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: icon.color, .link: url, .paragraphStyle: para]
        out.append(NSAttributedString(string: icon.glyph + "  " + e.name + (e.isDir ? "/" : ""),
                                      attributes: attrs))
        let date = e.modified.map { "\t" + listingDate($0, now: now) } ?? ""
        out.append(NSAttributedString(string: date + "\n",
                                      attributes: [.font: font, .foregroundColor: dim,
                                                   .link: url, .paragraphStyle: para]))
    }
    if contents.omitted > 0 {
        out.append(NSAttributedString(string: "\n  … and \(contents.omitted) more entries\n",
                                      attributes: [.font: font,
                                                   .foregroundColor: fg.withAlphaComponent(0.6)]))
    }
    return out
}

/// Render yazi's selection (⌘L) as a clickable list in the folder-listing
/// style: icon + name per row, the parent directory dimmed behind it (the
/// selection spans directories, so the name alone would not say WHERE the file
/// is). Rows carry the same .link contract as the folder listing — clicking a
/// directory cds yazi there, clicking a file reveals it. Paths keep yazi's
/// selection order. Does filesystem stats (isDirectory per path) — call off
/// the main thread like `renderListing`'s loader.
func renderSelectedListing(_ paths: [String]) -> NSAttributedString {
    let pal = activePalette()
    let fg = nsColor(pal.fg), blue = nsColor(pal.ansi[4])
    let font = terminalFont()
    if paths.isEmpty {
        return NSAttributedString(string: "  (nothing selected — Space or v marks files in yazi)",
                                  attributes: [.font: font, .foregroundColor: fg])
    }
    let out = NSMutableAttributedString()
    out.append(NSAttributedString(string: "  \(paths.count) selected\n\n",
                                  attributes: [.font: font,
                                               .foregroundColor: nsColor(pal.ansi[3])]))
    for path in paths {
        let ns = path as NSString
        let name = ns.lastPathComponent
        let isDir = isDirectory(path)
        let icon = isDir ? FileIcon(glyph: "\u{f07b}", color: blue) : fileIcon(name, pal)
        let url = URL(fileURLWithPath: path, isDirectory: isDir)
        out.append(NSAttributedString(string: icon.glyph + "  " + name + (isDir ? "/" : ""),
                                      attributes: [.font: font, .foregroundColor: icon.color,
                                                   .link: url]))
        out.append(NSAttributedString(string: "   " + ns.deletingLastPathComponent + "\n",
                                      attributes: [.font: font,
                                                   .foregroundColor: fg.withAlphaComponent(0.45)]))
    }
    return out
}
