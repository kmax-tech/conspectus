import Cocoa
import ConspectusCore
import SwiftTerm

// Appearance: palette plumbing, fonts, and the folder-listing renderer.
// Follow the macOS system appearance: Catppuccin Latte in light mode, Mocha in
// dark. yazi picks its matching flavor by querying our background via OSC 11
// (SwiftTerm answers), so the whole panel stays one coherent theme.

func systemIsDark() -> Bool {
    UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
}

func activePalette() -> Palette { systemIsDark() ? mocha : latte }

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
// folders first, natural sort, Nerd Font glyphs, Catppuccin colors per type.
// Loading (ConspectusCore.loadFolder: bulk isDirectory keys, sort, cap)
// happens off the main thread; only a screenful is rendered anyway, and
// "… and N more" makes the cut visible.
let folderListingCap = 500

/// Render loaded folder contents in the current theme. Does no I/O — safe to
/// build off the main thread; TextKit layout happens when the result is
/// applied to the text view on main. Directory rows carry a .link with their
/// URL so a click can navigate yazi there (mimicking yazi's own 3rd column).
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
    let out = NSMutableAttributedString()
    for e in contents.entries {
        let icon = e.isDir ? FileIcon(glyph: "\u{f07b}", color: blue)   // nf-fa-folder for dirs
                           : fileIcon(e.name, pal)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: icon.color]
        if e.isDir {
            attrs[.link] = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(e.name),
                               isDirectory: true)
        }
        out.append(NSAttributedString(string: icon.glyph + "  " + e.name + (e.isDir ? "/" : "") + "\n",
                                      attributes: attrs))
    }
    if contents.omitted > 0 {
        out.append(NSAttributedString(string: "\n  … and \(contents.omitted) more entries\n",
                                      attributes: [.font: font,
                                                   .foregroundColor: fg.withAlphaComponent(0.6)]))
    }
    return out
}
