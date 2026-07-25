import Foundation

// Which files preview as text in the NATIVE in-process NSTextView instead of
// going through Quick Look. Pure classification — the caller does the I/O.
// The point (see the hardening note): source/config/notes/data are the most
// hovered and, for markdown, the most crash-prone (QLMarkdown → WebKit), so
// routing them to our own view takes them off the fragile Quick Look path.
// Unknown types fall back to Quick Look.

/// Real file extensions (lowercased, no dot) that render as text.
public let textPreviewExtensions: Set<String> = [
    // prose / notes / docs
    "txt", "md", "markdown", "org", "rst", "adoc", "typ", "qmd", "rmd", "text",
    // TeX
    "tex", "bib", "sty", "cls", "bst", "dtx", "ins",
    // source
    "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "c", "h", "cpp", "cc",
    "hpp", "hh", "m", "mm", "rs", "go", "lua", "rb", "pl", "pm", "php", "java",
    "kt", "kts", "scala", "clj", "hs", "ml", "el", "lisp", "vim", "r", "jl",
    "dart", "zig", "nim", "ex", "exs",
    // shell / config
    "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
    "json", "jsonl", "ndjson", "toml", "yaml", "yml", "xml", "plist",
    "html", "htm", "css", "scss", "sass", "less",
    "conf", "cfg", "ini", "env", "properties", "editorconfig",
    // data / misc
    "csv", "tsv", "sql", "log", "diff", "patch", "gitignore", "gitattributes",
    "gitconfig", "srt", "vtt", "gql", "graphql", "proto", "svg",
]

/// Extension-less basenames that are text (Makefile, Dockerfile, dotfiles …).
public let textPreviewBasenames: Set<String> = [
    "Makefile", "makefile", "GNUmakefile", "Dockerfile", "Containerfile",
    "Gemfile", "Rakefile", "Procfile", "Brewfile", "Justfile", "justfile",
    "LICENSE", "README", "CHANGELOG", "TODO", "NOTES", "AUTHORS", "COPYING",
    ".gitignore", ".gitattributes", ".gitconfig", ".zshrc", ".zprofile",
    ".zshenv", ".bashrc", ".bash_profile", ".profile", ".vimrc", ".inputrc",
    ".editorconfig", ".npmrc", ".curlrc", ".tmux.conf",
]

/// True if the file at `path` should preview as text (native), decided by
/// extension, else by known basename. Pure — no filesystem access.
public func isTextPreviewable(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    if !ext.isEmpty, textPreviewExtensions.contains(ext) { return true }
    // pathExtension is empty for dotfiles like ".gitignore" and for
    // extension-less names like "Makefile" — match those by full basename.
    return textPreviewBasenames.contains(name)
}

/// Raster image extensions that preview in the native NSImageView (in-process)
/// instead of Quick Look. SVG is NOT here — it's XML, handled as text above.
public let imagePreviewExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif",
    "webp", "ico", "icns", "avif", "jp2", "jpf", "psd",
]

/// True if the file at `path` should preview as a native image. Pure.
public func isImagePreviewable(_ path: String) -> Bool {
    let ext = ((path as NSString).lastPathComponent as NSString).pathExtension.lowercased()
    return !ext.isEmpty && imagePreviewExtensions.contains(ext)
}

/// Strip a leading YAML frontmatter block: if the text starts with a line that
/// is exactly `---`, drop everything up to and including the next `---` or
/// `...` delimiter line, plus any blank lines after it. Used by the RENDERED
/// markdown view so the metadata header (title/tags/note_id …) doesn't show;
/// the source view keeps the raw file. No closing delimiter → not treated as
/// frontmatter (returned unchanged). Pure.
public func stripFrontmatter(_ text: String) -> String {
    var body = Substring(text)
    if body.first == "\u{FEFF}" { body = body.dropFirst() }   // optional UTF-8 BOM
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
    func delim(_ l: Substring) -> String { l.trimmingCharacters(in: .whitespaces) }
    guard let first = lines.first, delim(first) == "---" else { return text }
    for i in 1..<lines.count {
        let d = delim(lines[i])
        guard d == "---" || d == "..." else { continue }
        var rest = Array(lines[(i + 1)...])
        while let f = rest.first, f.trimmingCharacters(in: .whitespaces).isEmpty { rest.removeFirst() }
        return rest.joined(separator: "\n")
    }
    return text   // opened but never closed → not valid frontmatter
}
