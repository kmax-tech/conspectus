import Foundation

// Companion-note lookup — perlege's `resolveNote` (services/notes.js), ported.
// Given a document (a PDF, typically), find its note `<stem>.md`: first
// locally next to the document (sibling, then subdirectories), then at the
// symlink target's real location (projects symlink pdf+md into the library,
// so the project's own md wins first and preserves project context), then
// flat in the central notes dirs using the CANONICAL stem (never the alias,
// to avoid false matches). Nothing is ever created here — the caller decides
// where a new note goes (`defaultNotePath`: locally, never centrally; the
// central library is scrinium's to manage).
//
// Deviation from perlege, deliberate: the subdirectory descent is capped
// (depth + hidden dirs skipped) because conspectus resolves on HOVER — an
// unbounded recursion under a big tree (node_modules, a data dir) must not
// stall the preview pipeline. perlege resolves on explicit open and can
// afford the full walk.

/// Central notes dirs fallback (CONSPECTUS_NOTES_DIRS unset).
public let defaultNotesDir = "~/work/library/notes"

/// How deep below the document's directory the local search descends.
let noteSearchMaxDepth = 3

/// Parse the CONSPECTUS_NOTES_DIRS value: comma-separated directories,
/// whitespace trimmed, tilde expanded against `home`, empty entries dropped.
/// nil (unset) yields the default library dir. Pure.
public func parseNotesDirs(_ raw: String?, home: String = NSHomeDirectory()) -> [String] {
    let value = raw ?? defaultNotesDir
    return value.split(separator: ",").compactMap { part in
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        return trimmed
    }
}

/// The document's note stem: filename without its extension.
private func noteStem(_ path: String) -> String {
    ((path as NSString).lastPathComponent as NSString).deletingPathExtension
}

/// Depth-first search for `<stem>.md` in the subdirectories of `dir`, capped
/// at `depth` levels; hidden directories are skipped (a `.git` walk on hover
/// would be pure waste). Deliberate `try?` on the listing: an unreadable
/// directory simply has no note for us.
private func findNoteInSubdirs(_ dir: String, stem: String, depth: Int) -> String? {
    guard depth > 0,
          let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
    for name in entries.sorted() where !name.hasPrefix(".") {
        let child = (dir as NSString).appendingPathComponent(name)
        guard isDirectory(child) else { continue }
        let candidate = (child as NSString).appendingPathComponent(stem + ".md")
        if FileManager.default.fileExists(atPath: candidate) { return candidate }
        if let deeper = findNoteInSubdirs(child, stem: stem, depth: depth - 1) { return deeper }
    }
    return nil
}

/// The local half of the lookup: sibling `<dir>/<stem>.md`, else the capped
/// subdirectory descent (covers a `notes/` folder next to the document).
private func resolveNoteLocally(_ dir: String, stem: String) -> String? {
    let sibling = (dir as NSString).appendingPathComponent(stem + ".md")
    if FileManager.default.fileExists(atPath: sibling) { return sibling }
    return findNoteInSubdirs(dir, stem: stem, depth: noteSearchMaxDepth)
}

/// Resolve the companion note for the document at `path`, or nil if none
/// exists. Order (first hit wins): local at the path as given → local at the
/// symlink-resolved real location → flat `<notesDir>/<canonicalStem>.md` per
/// central dir. Reads the filesystem; creates nothing.
public func resolveNote(for path: String, notesDirs: [String]) -> String? {
    if let local = resolveNoteLocally((path as NSString).deletingLastPathComponent,
                                      stem: noteStem(path)) {
        return local
    }
    let canonical = (path as NSString).resolvingSymlinksInPath
    if canonical != path,
       let real = resolveNoteLocally((canonical as NSString).deletingLastPathComponent,
                                     stem: noteStem(canonical)) {
        return real
    }
    for notesDir in notesDirs {
        let central = (notesDir as NSString).appendingPathComponent(noteStem(canonical) + ".md")
        if FileManager.default.fileExists(atPath: central) { return central }
    }
    return nil
}

/// Where a NEW note for `path` belongs: `<stem>.md` right next to the
/// document as opened (the working/symlink location — never the central
/// library). The file need not exist; the editor materializes it on save. Pure.
public func defaultNotePath(for path: String) -> String {
    ((path as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent(noteStem(path) + ".md")
}
