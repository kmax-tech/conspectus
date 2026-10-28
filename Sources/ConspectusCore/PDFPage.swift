import Foundation

// A hover that carries a PDF page. The preview FIFO normally transports a
// bare absolute path, and the app opens a freshly loaded PDF on page 1. A
// content search through ripgrep-all (yazi's `S` with M-a, the shell's
// `rgai`) knows the PAGE of a hit, so it writes `@PDFPAGE:<page>:<path>`
// instead: the same hover, plus where to land. Parsed here, acted on by the
// shell's PDF preview.

/// A hover onto `path` that asks the PDF preview to show `page` (1-based,
/// as ripgrep-all prints it: `Page 3: …`).
public struct PDFPageHover: Equatable {
    public let page: Int
    public let path: String

    public init(page: Int, path: String) {
        self.page = page
        self.path = path
    }
}

/// Parse the body of a `@PDFPAGE:` FIFO message (everything after the
/// prefix): `<page>:<absolute path>`. Only the FIRST colon separates the
/// page; later ones belong to the path. Returns nil when the page is not a
/// positive integer or the path is not absolute — the caller warns, never
/// guesses a page.
public func parsePDFPageMessage(_ body: String) -> PDFPageHover? {
    guard let colon = body.firstIndex(of: ":"),
          let page = Int(body[..<colon]), page >= 1 else { return nil }
    let path = String(body[body.index(after: colon)...])
    guard path.hasPrefix("/") else { return nil }
    return PDFPageHover(page: page, path: path)
}
