import AppKit

// Pure logic behind the right pane's folder look-ahead listing: entry
// ordering (mirroring yazi's sort preference), the size and date column
// formats and the extension -> icon mapping. The rendering (fonts,
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
    /// Creation date (yazi's "btime"); nil if it could not be read. Only used
    /// for ordering, never shown.
    public let created: Date?

    public init(name: String, isDir: Bool, modified: Date? = nil, size: Int? = nil,
                created: Date? = nil) {
        self.name = name
        self.isDir = isDir
        self.modified = modified
        self.size = size
        self.created = created
    }
}

/// How a folder listing is ordered — yazi's sort preference, which the bundled
/// plugin announces over the FIFO (`@SORT:<by>:<reverse>:<dir_first>`) before
/// every hover, so the pane lists a folder the way yazi lists its own columns
/// (`, t` and the other `,` keys reach the pane).
public struct ListingSort: Equatable {
    /// yazi's `sort_by` values. `random` and `none` cannot be mirrored (one is
    /// per-process randomness, the other readdir order) and fall back to
    /// `natural` — documented here, not warned about: both are legitimate
    /// yazi states, not errors.
    public enum By: String, CaseIterable {
        case natural, alphabetical, mtime, btime, size, `extension`, random, none
    }
    public let by: By
    public let reverse: Bool
    public let dirFirst: Bool

    public init(by: By, reverse: Bool, dirFirst: Bool) {
        self.by = by
        self.reverse = reverse
        self.dirFirst = dirFirst
    }

    /// The order before the first `@SORT` arrives (and in tests): natural,
    /// directories first — this user's yazi.toml and yazi's own dir-first preset.
    public static let `default` = ListingSort(by: .natural, reverse: false, dirFirst: true)
}

/// Parse the body of a `@SORT:` FIFO message: `<by>:<reverse>:<dir_first>`,
/// the flags spelled `true`/`false` (Lua's `tostring` of a boolean). nil for
/// anything else — the caller warns and keeps the previous order; bad input
/// is never coerced into a default.
public func parseListingSort(_ body: String) -> ListingSort? {
    let parts = body.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, let by = ListingSort.By(rawValue: String(parts[0])),
          let reverse = Bool(String(parts[1])), let dirFirst = Bool(String(parts[2])) else {
        return nil
    }
    return ListingSort(by: by, reverse: reverse, dirFirst: dirFirst)
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

/// Shorten a name for the listing's name column the way yazi's current pane
/// does (`Entity:ellipsis` + `Line:truncate`): a name that fits is returned
/// untouched; a longer one is cut from the right and ends in "…" — for a file
/// with an extension in "….ext", so the type stays readable ("lenz09-sozio….pdf").
/// Directories keep their trailing "/" after the ellipsis ("very-long-na…/").
/// The result never exceeds `max` characters. Width counts characters, not
/// terminal cells (CJK/emoji are two cells; known limit, see TODO.md).
///
/// - Parameters:
///   - name: The entry's file name (without a trailing "/").
///   - isDir: Whether a "/" is appended for display.
///   - max: Column width in characters; at least 2 ("…/" must fit).
/// - Returns: The display name, at most `max` characters.
public func truncateName(_ name: String, isDir: Bool, max: Int) -> String {
    precondition(max >= 2, "column width must hold at least \"…/\", got \(max)")
    let suffix = isDir ? "/" : ""
    if name.count + suffix.count <= max { return name + suffix }
    // Extension like Rust's Path::extension: after the last dot, but a
    // leading dot (".bashrc") is not an extension.
    var ellipsis = "…"
    if !isDir, let dot = name.lastIndex(of: "."), dot != name.startIndex,
       name.index(after: dot) != name.endIndex {
        let withExt = "…" + name[dot...]
        // A long extension that leaves no room for the stem falls back to "…".
        if withExt.count + suffix.count < max { ellipsis = withExt }
    }
    let keep = Swift.max(0, max - ellipsis.count - suffix.count)
    return String(name.prefix(keep)) + ellipsis + suffix
}

/// Format a modification date for the listing's date column, the same way
/// yazi's `size_and_mtime` linemode does: today and yesterday by name ("y-day",
/// the Finder convention — recent work reads at a glance; abbreviated so the
/// day field is as wide as "16.10." and the columns sit close), the rest of this year
/// with the time, older or future years with the year (the `ls -l`
/// convention). Always 12 characters, time or year flush right:
///
///     today  14:32
///     y-day  09:10
///     16.10. 14:32
///     15.01.  2024
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
    if cal.isDate(date, inSameDayAs: now) { return "today  " + format("HH:mm") }
    if cal.isDate(date, inSameDayAs: yesterday) { return "y-day  " + format("HH:mm") }
    if cal.component(.year, from: date) == cal.component(.year, from: now) {
        return format("dd.MM. HH:mm")
    }
    return format("dd.MM.  yyyy")
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

/// Order entries the way yazi orders them under `sort` (yazi-fs/sorter.rs):
/// directories promoted first when `dirFirst` (never reversed), then the sort
/// key, ties broken by name; `reverse` flips key and tie-break alike. The
/// comparisons approximate yazi's byte-level ones with Foundation's:
/// `localizedStandardCompare` for natural ("file2" before "file10"),
/// case-insensitive compare for alphabetical and extensions. A missing date
/// sorts as the oldest, a directory's size as 0, a directory's extension as
/// empty — each what yazi does with its 0 / len / no-ext equivalents.
public func sortEntries(_ entries: [DirEntry], _ sort: ListingSort = .default) -> [DirEntry] {
    func key(_ a: DirEntry, _ b: DirEntry) -> ComparisonResult {
        switch sort.by {
        case .natural, .random, .none:
            return a.name.localizedStandardCompare(b.name)
        case .alphabetical:
            return a.name.caseInsensitiveCompare(b.name)
        case .mtime:
            return compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .btime:
            return compare(a.created ?? .distantPast, b.created ?? .distantPast)
        case .size:
            return compare(a.size ?? 0, b.size ?? 0)
        case .extension:
            let ea = a.isDir ? "" : (a.name as NSString).pathExtension
            let eb = b.isDir ? "" : (b.name as NSString).pathExtension
            return ea.caseInsensitiveCompare(eb)
        }
    }
    return entries.sorted { a, b in
        if sort.dirFirst && a.isDir != b.isDir { return a.isDir }
        var ord = key(a, b)
        if ord == .orderedSame { ord = a.name.compare(b.name) }   // yazi's alphabetical fallback
        return (ord == .orderedAscending) != sort.reverse && ord != .orderedSame
    }
}

/// `ComparisonResult` for any `Comparable` — Foundation only offers it on
/// strings and numbers.
private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
}

/// Contents of a folder prepared for the look-ahead listing.
public struct FolderContents: Equatable {
    /// Entries in display order (see `sortEntries`), capped.
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
/// dates bulk-fetched during enumeration (one getattrlistbulk kernel pass,
/// no stat per entry), ordered by `sort` (see `sortEntries`) over all
/// entries, then capped to `cap` for display. Safe to call off the main thread.
///
/// The URL to enumerate a directory with, symlinks resolved. Needed because
/// `FileManager.contentsOfDirectory(at:)` refuses a symlink to a directory
/// when the URL was built with `isDirectory: true` (ENOTDIR, "Not a
/// directory"), so a folder reached through a link (`~/work/areas/x ->
/// ~/cvsrepo/...`) would otherwise list as empty or as an error.
///
/// Side effects: reads the link chain from disk.
func directoryURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
}

/// A read failure is returned as `error` rather than thrown — the folder
/// vanishing mid-hover is an expected race, and the caller renders the error
/// into the pane (visible, not swallowed).
///
/// Side effects: reads the directory from disk.
public func loadFolder(_ dir: String, cap: Int, sort: ListingSort = .default) -> FolderContents {
    let listingKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                         .contentModificationDateKey, .creationDateKey]
    let urls: [URL]
    do {
        urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL(dir),
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
                        size: isDir ? nil : values?.fileSize,
                        created: values?.creationDate)
    }
    let capped = capEntries(sortEntries(all, sort), limit: cap)
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
