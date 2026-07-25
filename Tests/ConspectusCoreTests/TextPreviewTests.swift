import XCTest
@testable import ConspectusCore

final class TextPreviewTests: XCTestCase {
    func testCommonSourceAndDocExtensions() {
        for p in ["/a/b/notes.md", "/x/paper.tex", "/x/refs.bib", "/s/main.swift",
                  "/d/data.json", "/c/config.toml", "/l/run.log", "/w/index.html",
                  "/n/note.qmd", "/s/build.sh", "/z/.config/foo.yaml"] {
            XCTAssertTrue(isTextPreviewable(p), "\(p) should preview as text")
        }
    }

    func testCaseInsensitiveExtension() {
        XCTAssertTrue(isTextPreviewable("/x/README.MD"))
        XCTAssertTrue(isTextPreviewable("/x/Photo.PY"))   // extension, not the word
    }

    func testExtensionlessAndDotfileBasenames() {
        for p in ["/proj/Makefile", "/proj/Dockerfile", "/proj/LICENSE",
                  "/home/max/.gitignore", "/home/max/.zshrc", "/home/max/.vimrc"] {
            XCTAssertTrue(isTextPreviewable(p), "\(p) should preview as text")
        }
    }

    func testNonTextFallsBackToQuickLook() {
        for p in ["/x/paper.pdf", "/x/photo.png", "/x/clip.mp4", "/x/song.mp3",
                  "/x/archive.zip", "/x/sheet.xlsx", "/x/font.ttf", "/x/unknownfile"] {
            XCTAssertFalse(isTextPreviewable(p), "\(p) should fall back to Quick Look")
        }
    }

    func testImageExtensions() {
        for p in ["/x/photo.png", "/x/scan.JPG", "/x/anim.gif", "/x/pic.heic",
                  "/x/logo.webp", "/x/icon.icns"] {
            XCTAssertTrue(isImagePreviewable(p), "\(p) should preview as image")
        }
    }

    func testStripFrontmatter() {
        let withFm = "---\ntitle: Hi\ntags:\n  - a\n---\n\n# Heading\n\nBody."
        XCTAssertEqual(stripFrontmatter(withFm), "# Heading\n\nBody.")
        // closed with ...
        XCTAssertEqual(stripFrontmatter("---\nid: x\n...\n# H"), "# H")
        // no frontmatter → unchanged
        XCTAssertEqual(stripFrontmatter("# Heading\n\n---\n\nmore"), "# Heading\n\n---\n\nmore")
        // opened but never closed → unchanged (not valid)
        let unclosed = "---\ntitle: Hi\n# H"
        XCTAssertEqual(stripFrontmatter(unclosed), unclosed)
        // a --- rule mid-document is not stripped
        XCTAssertEqual(stripFrontmatter("text\n---\nmore"), "text\n---\nmore")
    }

    func testImageVsTextVsOther() {
        XCTAssertTrue(isTextPreviewable("/x/diagram.svg"))    // SVG is XML → text
        XCTAssertFalse(isImagePreviewable("/x/diagram.svg"))
        XCTAssertFalse(isImagePreviewable("/x/notes.md"))
        XCTAssertFalse(isImagePreviewable("/x/paper.pdf"))    // PDF has its own path
        XCTAssertFalse(isImagePreviewable("/x/clip.mp4"))     // video → Quick Look
    }
}
