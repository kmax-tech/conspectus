import AppKit

// Pure logic behind the right pane's folder look-ahead listing: entry
// ordering, the date column format and the extension -> icon mapping. The rendering (fonts,
// NSAttributedString, filesystem reads) stays in the app.

/// One entry of a folder listing.
public struct DirEntry: Equatable {
    public let name: String
    public let isDir: Bool
    /// Modification date; nil if it could not be read (entry vanished
    /// mid-enumeration) — the listing then leaves the date column blank.
    public let modified: Date?
    /// File size in bytes; nil for directories (shown as "-", like yazi) and
    /// when it could not be read.
    public let size: Int?

    public init(name: String, isDir: Bool, modified: Date? = nil, size: Int? = nil) {
        self.name = name
        self.isDir = isDir
        self.modified = modified
        self.size = size
    }
}

/// Format a byte count for the listing's size column the way yazi's
/// `ya.readable_size` does, so the pane and the yazi linemode read the same:
/// binary units (1K = 1024 B), one decimal, a trailing ".0" dropped —
/// "807B", "32K", "612.4K", "2.8M".
public func readableSize(_ bytes: Int) -> String {
    precondition(bytes >= 0, "size must be non-negative, got \(bytes)")
    let units = ["B", "K", "M", "G", "T", "P", "E"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    var number = String(format: "%.1f", value)
    if number.hasSuffix(".0") { number.removeLast(2) }
    return number + units[unit]
}

/// Format a modification date for the listing's date column, the same way
/// yazi's `size_and_mtime` linemode does: today and yesterday by name (the
/// Finder convention — recent work reads at a glance), the rest of this year
/// with the time, older or future years with the year (the `ls -l`
/// convention). Always 15 characters, time or year flush right:
///
///     today     14:32
///     yesterday 09:10
///     16.10.    14:32
///     15.01.     2024
///
/// - Parameters:
///   - date: The modification date to show.
///   - now: Reference "today" (injectable for tests).
///   - timeZone: Zone the date is shown in (default: the system's).
public func listingDate(_ date: Date, now: Date = Date(),
                        timeZone: TimeZone = .current) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    func format(_ pattern: String) -> String {
        f.dateFormat = pattern
        return f.string(from: date)
    }
    // Force-unwrap: subtracting one day from a valid date always succeeds.
    let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
    if cal.isDate(date, inSameDayAs: now) { return "today     " + format("HH:mm") }
    if cal.isDate(date, inSameDayAs: yesterday) { return "yesterday " + format("HH:mm") }
    if cal.component(.year, from: date) == cal.component(.year, from: now) {
        return format("dd.MM.    HH:mm")
    }
    return format("dd.MM.     yyyy")
}

/// Cap an already-sorted entry list for display: the first `limit` entries
/// plus how many were omitted. The caller sorts first (see `sortEntries`), so
/// directories-first order survives the cap — the isDir bit comes for free
/// from the bulk enumeration, capping only bounds the *rendering* cost.
///
/// - Parameters:
///   - entries: Entries in display order (sort before capping).
///   - limit: Maximum number of entries to keep; must be positive.
/// - Returns: `shown` (at most `limit` entries) and `omitted` (how many were
///   cut, 0 if none).
public func capEntries(_ entries: [DirEntry], limit: Int) -> (shown: [DirEntry], omitted: Int) {
    precondition(limit > 0, "limit must be positive, got \(limit)")
    if entries.count <= limit { return (entries, 0) }
    return (Array(entries.prefix(limit)), entries.count - limit)
}

/// Order entries the way the folder listing shows them: directories first,
/// then natural (Finder-like) name order, so "file2" sorts before "file10".
public func sortEntries(_ entries: [DirEntry]) -> [DirEntry] {
    entries.sorted { a, b in
        if a.isDir != b.isDir { return a.isDir }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Contents of a folder prepared for the look-ahead listing.
public struct FolderContents: Equatable {
    /// Entries in display order (directories first, natural sort), capped.
    public let entries: [DirEntry]
    /// How many entries the cap cut off (0 if none).
    public let omitted: Int
    /// Non-nil if the folder could not be read; `entries` is empty then.
    public let error: String?

    public init(entries: [DirEntry], omitted: Int, error: String? = nil) {
        self.entries = entries
        self.omitted = omitted
        self.error = error
    }
}

/// Read a folder for the look-ahead listing: isDirectory bits, sizes and
/// modification dates bulk-fetched during enumeration (one getattrlistbulk kernel pass, no stat per entry),
/// directories-first natural sort over all entries, then capped to `cap` for
/// display. Safe to call off the main thread.
///
/// A read failure is returned as `error` rather than thrown — the folder
/// vanishing mid-hover is an expected race, and the caller renders the error
/// into the pane (visible, not swallowed).
///
/// Side effects: reads the directory from disk.
public func loadFolder(_ dir: String, cap: Int) -> FolderContents {
    let listingKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
    let urls: [URL]
    do {
        urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir, isDirectory: true),
            includingPropertiesForKeys: listingKeys,
            options: [.skipsHiddenFiles])
    } catch {
        return FolderContents(entries: [], omitted: 0, error: error.localizedDescription)
    }
    let all = urls.map { url -> DirEntry in
        // Deliberate try?: the keys were prefetched, a miss means the entry
        // vanished mid-enumeration — rendering it as a dateless, sizeless file is
        // cosmetics, not worth failing the whole listing.
        let values = try? url.resourceValues(forKeys: Set(listingKeys))
        let isDir = values?.isDirectory ?? false
        return DirEntry(name: url.lastPathComponent,
                        isDir: isDir,
                        modified: values?.contentModificationDate,
                        size: isDir ? nil : values?.fileSize)
    }
    let capped = capEntries(sortEntries(all), limit: cap)
    return FolderContents(entries: capped.shown, omitted: capped.omitted)
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
