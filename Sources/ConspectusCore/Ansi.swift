import Foundation

// Parse `bat --color=always` output (ANSI SGR escape sequences) into styled
// runs. Pure logic — no AppKit — so it lives here and is unit-tested; the
// executable maps `AnsiRun` to NSAttributedString/NSColor. bat emits truecolor
// (`\e[38;2;R;G;Bm`) from the Catppuccin themes, but 256-color, 16-color, and
// the bold/italic/underline styles are handled too for robustness.

public struct RGB: Equatable {
    public let r, g, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// A maximal stretch of text sharing the same styling. `fg == nil` means the
/// default foreground; `bg == nil` means the themed pane background (glow's
/// code blocks / some themes set a background). `bg` defaults to nil so the
/// text-only callers and tests need not mention it.
public struct AnsiRun: Equatable {
    public let text: String
    public let fg: RGB?
    public let bg: RGB?
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public init(text: String, fg: RGB?, bold: Bool, italic: Bool, underline: Bool, bg: RGB? = nil) {
        self.text = text; self.fg = fg; self.bg = bg
        self.bold = bold; self.italic = italic; self.underline = underline
    }
}

/// Standard xterm 16-colour palette (for 30–37 / 90–97 codes). bat truecolor
/// output rarely uses these, but a robust parser handles them.
private let ansi16: [RGB] = [
    RGB(0,0,0), RGB(205,0,0), RGB(0,205,0), RGB(205,205,0),
    RGB(0,0,238), RGB(205,0,205), RGB(0,205,205), RGB(229,229,229),
    RGB(127,127,127), RGB(255,0,0), RGB(0,255,0), RGB(255,255,0),
    RGB(92,92,255), RGB(255,0,255), RGB(0,255,255), RGB(255,255,255),
]

/// Map an xterm 256-colour index to RGB (0–15 palette, 16–231 cube, 232–255 grey).
private func xterm256(_ n: Int) -> RGB {
    if n < 16 { return ansi16[n] }
    if n >= 232 { let v = UInt8(8 + (n - 232) * 10); return RGB(v, v, v) }
    let i = n - 16
    let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
    return RGB(steps[(i / 36) % 6], steps[(i / 6) % 6], steps[i % 6])
}

/// Parse ANSI SGR-coloured text into styled runs. Non-SGR escape sequences are
/// skipped; the text between escapes is emitted with the current style.
public func parseANSI(_ input: String) -> [AnsiRun] {
    var runs: [AnsiRun] = []
    var fg: RGB? = nil
    var bg: RGB? = nil
    var bold = false, italic = false, underline = false
    var buf = ""
    let chars = Array(input.unicodeScalars)
    var i = 0

    func flush() {
        guard !buf.isEmpty else { return }
        runs.append(AnsiRun(text: buf, fg: fg, bold: bold, italic: italic, underline: underline, bg: bg))
        buf = ""
    }

    while i < chars.count {
        let c = chars[i]
        if c == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
            // Read the CSI sequence up to its final byte (a letter).
            var j = i + 2
            var params = ""
            while j < chars.count, !(chars[j] >= "@" && chars[j] <= "~") { params.unicodeScalars.append(chars[j]); j += 1 }
            let final = j < chars.count ? chars[j] : "m"
            if final == "m" {
                flush()
                applySGR(params, &fg, &bg, &bold, &italic, &underline)
            }
            i = j + 1
            continue
        }
        buf.unicodeScalars.append(c)
        i += 1
    }
    flush()
    return runs
}

/// Apply one `\e[…m` parameter list to the running style (foreground,
/// background, and the bold/italic/underline flags).
private func applySGR(_ params: String, _ fg: inout RGB?, _ bg: inout RGB?,
                      _ bold: inout Bool, _ italic: inout Bool, _ underline: inout Bool) {
    let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    if codes.isEmpty { fg = nil; bg = nil; bold = false; italic = false; underline = false; return }
    var k = 0
    while k < codes.count {
        switch codes[k] {
        case 0: fg = nil; bg = nil; bold = false; italic = false; underline = false
        case 1: bold = true
        case 22: bold = false
        case 3: italic = true
        case 23: italic = false
        case 4: underline = true
        case 24: underline = false
        case 30...37: fg = ansi16[codes[k] - 30]
        case 90...97: fg = ansi16[codes[k] - 90 + 8]
        case 39: fg = nil
        case 40...47: bg = ansi16[codes[k] - 40]
        case 100...107: bg = ansi16[codes[k] - 100 + 8]
        case 49: bg = nil
        case 38, 48:
            let isFg = codes[k] == 38
            var colour: RGB? = nil
            if k + 1 < codes.count, codes[k + 1] == 5, k + 2 < codes.count {
                colour = xterm256(codes[k + 2]); k += 2
            } else if k + 1 < codes.count, codes[k + 1] == 2, k + 4 < codes.count {
                colour = RGB(UInt8(clamping: codes[k + 2]), UInt8(clamping: codes[k + 3]), UInt8(clamping: codes[k + 4])); k += 4
            }
            if isFg { fg = colour } else { bg = colour }
        default: break
        }
        k += 1
    }
}
