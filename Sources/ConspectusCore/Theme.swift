import AppKit

// Color primitives shared by the terminal theming and the folder listing.
// Palettes are compile-time constants, so anything invalid should fail loudly
// at startup — never render silently as black.

/// Error thrown when a hex color literal cannot be parsed.
public enum ColorError: Error, Equatable {
    case invalidHex(String)
}

/// Parse a 6-digit `RRGGBB` hex string into its numeric value.
///
/// - Parameter hex: Color as exactly six hex digits, e.g. `"1E1E2E"`.
/// - Returns: The 24-bit color value.
/// - Throws: `ColorError.invalidHex` if `hex` is not six valid hex digits.
public func parseHexColor(_ hex: String) throws -> UInt32 {
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else {
        throw ColorError.invalidHex(hex)
    }
    return v
}

/// A 16-color terminal palette plus background/foreground/cursor, as `RRGGBB`
/// hex strings. The initializer validates every entry: palettes are hardcoded
/// constants, so a typo crashes at first use with a clear message instead of
/// rendering as black (fail loud).
public struct Palette {
    /// ANSI colors: indices 0–7 normal, 8–15 bright.
    public let ansi: [String]
    public let bg: String
    public let fg: String
    public let cursor: String

    public init(ansi: [String], bg: String, fg: String, cursor: String) {
        precondition(ansi.count == 16, "palette needs exactly 16 ANSI colors, got \(ansi.count)")
        for hex in ansi + [bg, fg, cursor] {
            precondition((try? parseHexColor(hex)) != nil, "invalid hex color in palette: \(hex)")
        }
        self.ansi = ansi
        self.bg = bg
        self.fg = fg
        self.cursor = cursor
    }
}

/// Catppuccin Mocha — the dark-mode palette.
public let mocha = Palette(
    ansi: ["45475A", "F38BA8", "A6E3A1", "F9E2AF", "89B4FA", "F5C2E7", "94E2D5", "BAC2DE",
           "585B70", "F38BA8", "A6E3A1", "F9E2AF", "89B4FA", "F5C2E7", "94E2D5", "A6ADC8"],
    bg: "1E1E2E", fg: "CDD6F4", cursor: "F5E0DC")

/// Catppuccin Latte — the light-mode palette.
public let latte = Palette(
    ansi: ["5C5F77", "D20F39", "40A02B", "DF8E1D", "1E66F5", "EA76CB", "179299", "ACB0BE",
           "6C6F85", "D20F39", "40A02B", "DF8E1D", "1E66F5", "EA76CB", "179299", "BCC0CC"],
    bg: "EFF1F5", fg: "4C4F69", cursor: "DC8A78")

/// `NSColor` from a palette hex string.
///
/// Callers pass values out of a `Palette`, whose initializer already validated
/// them — so an invalid string here is a programmer error and `try!` crashes
/// with the parse error rather than substituting a wrong color.
public func nsColor(_ hex: String) -> NSColor {
    let v = try! parseHexColor(hex)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
