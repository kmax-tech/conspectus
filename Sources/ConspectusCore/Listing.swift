import AppKit

// Pure logic behind the right pane's folder look-ahead listing: entry
// ordering and the extension -> icon mapping. The rendering (fonts,
// NSAttributedString, filesystem reads) stays in the app.

/// One entry of a folder listing.
public struct DirEntry: Equatable {
    public let name: String
    public let isDir: Bool

    public init(name: String, isDir: Bool) {
        self.name = name
        self.isDir = isDir
    }
}

/// Order entries the way the folder listing shows them: directories first,
/// then natural (Finder-like) name order, so "file2" sorts before "file10".
public func sortEntries(_ entries: [DirEntry]) -> [DirEntry] {
    entries.sorted { a, b in
        if a.isDir != b.isDir { return a.isDir }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Glyph + color a file gets in the folder listing.
public struct FileIcon: Equatable {
    public let glyph: String
    public let color: NSColor

    public init(glyph: String, color: NSColor) {
        self.glyph = glyph
        self.color = color
    }
}

/// Curated extension -> (Nerd Font glyph, Catppuccin color). Uses the reliable
/// Font Awesome file-type glyphs (f1c1–f1c9), so no tofu; colors approximate
/// yazi's per-type scheme rather than mirroring its exact icon set.
/// Unknown extensions get a generic file glyph in the foreground color.
public func fileIcon(_ name: String, _ pal: Palette) -> FileIcon {
    func c(_ i: Int) -> NSColor { nsColor(pal.ansi[i]) }   // 1 red 2 green 3 yellow 4 blue 5 pink 6 cyan
    let fg = nsColor(pal.fg)
    switch (name as NSString).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "tiff", "tif", "heic", "ico", "avif":
        return FileIcon(glyph: "\u{f1c5}", color: c(5))   // image
    case "pdf":
        return FileIcon(glyph: "\u{f1c1}", color: c(1))   // pdf
    case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst":
        return FileIcon(glyph: "\u{f1c6}", color: c(3))   // archive
    case "mp3", "wav", "flac", "m4a", "aac", "ogg":
        return FileIcon(glyph: "\u{f1c7}", color: c(2))   // audio
    case "mp4", "mov", "mkv", "avi", "webm", "m4v":
        return FileIcon(glyph: "\u{f1c8}", color: c(5))   // video
    case "md", "markdown", "rst", "txt", "text", "log", "org":
        return FileIcon(glyph: "\u{f15c}", color: fg)     // text
    case "py", "js", "ts", "tsx", "jsx", "lua", "c", "cpp", "h", "hpp", "go", "rs",
         "swift", "sh", "bash", "zsh", "fish", "rb", "java", "json", "jsonl", "json5",
         "yaml", "yml", "toml", "html", "css", "scss", "tex", "vim", "el":
        return FileIcon(glyph: "\u{f1c9}", color: c(2))   // code
    default:
        return FileIcon(glyph: "\u{f15b}", color: fg)     // generic file
    }
}
