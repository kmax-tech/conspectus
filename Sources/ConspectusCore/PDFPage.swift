import Foundation

// A hover that carries a PDF page, and optionally the word that was searched
// for. The preview FIFO normally transports a bare absolute path, and the app
// opens a freshly loaded PDF on page 1. A content search through ripgrep-all
// (yazi's `S` with M-a, the shell's `rgai`) knows the PAGE of a hit and the
// pattern it grepped for, so it writes `@PDFPAGE:<page>:<path>[\t<term>]`
// instead: the same hover, plus where to land and what to point at. Parsed
// here, acted on by the shell's PDF preview, which shows the term as a
// display-only highlight — nothing is written to the document.

/// A hover onto `path` that asks the PDF preview to show `page` (1-based,
/// as ripgrep-all prints it: `Page 3: …`) and, when `term` is set, to mark
/// every occurrence of that term on the page (literal, case-insensitive).
public struct PDFPageHover: Equatable {
    public let page: Int
    public let path: String
    public let term: String?

    public init(page: Int, path: String, term: String? = nil) {
        self.page = page
        self.path = path
        self.term = term
    }
}

/// Parse the body of a `@PDFPAGE:` FIFO message (everything after the
/// prefix): `<page>:<absolute path>` followed by an optional tab and the
/// search term. Only the FIRST colon separates the page; later ones belong
/// to the path. A tab separates path from term (yazi's own messages use the
/// same separator; a tab in a path is not supported anywhere in the app).
/// An empty term counts as none. Returns nil when the page is not a positive
/// integer or the path is not absolute — the caller warns, never guesses.
public func parsePDFPageMessage(_ body: String) -> PDFPageHover? {
    guard let colon = body.firstIndex(of: ":"),
          let page = Int(body[..<colon]), page >= 1 else { return nil }
    let rest = body[body.index(after: colon)...]
    let path: String
    var term: String? = nil
    if let tab = rest.firstIndex(of: "\t") {
        path = String(rest[..<tab])
        let t = String(rest[rest.index(after: tab)...])
        term = t.isEmpty ? nil : t
    } else {
        path = String(rest)
    }
    guard path.hasPrefix("/") else { return nil }
    return PDFPageHover(page: page, path: path, term: term)
}
