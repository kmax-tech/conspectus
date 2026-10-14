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

    func testMarkdownFiles() {
        for p in ["/a/notes.md", "/a/README.MD", "/a/doc.markdown"] {
            XCTAssertTrue(isMarkdownFile(p), "\(p) is markdown (render↔source toggle, typeset print)")
        }
        // Text, but not the markdown branch: .qmd/.rmd keep their source, and
        // an extension-less basename is never markdown.
        for p in ["/a/note.qmd", "/a/analysis.rmd", "/a/README", "/a/main.swift", "/a/paper.pdf"] {
            XCTAssertFalse(isMarkdownFile(p), "\(p) is not markdown")
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

    func testDecodeUTF8KeepsUmlauts() {
        XCTAssertEqual(decodeText(Data("Größe über".utf8)), "Größe über")
    }

    func testDecodeDropsUTF8BOM() {
        XCTAssertEqual(decodeText(Data([0xEF, 0xBB, 0xBF] + Array("ok".utf8))), "ok")
    }

    func testDecodeLatin1Umlauts() {
        // "Größe" as written by a Latin-1 editor: ö = F6, ß = DF.
        XCTAssertEqual(decodeText(Data([0x47, 0x72, 0xF6, 0xDF, 0x65])), "Größe")
    }

    func testDecodeWindows1252Quotes() {
        // „x“ — 84/93 are C1 controls in Latin-1, quotes in Windows-1252.
        XCTAssertEqual(decodeText(Data([0x84, 0x78, 0x93])), "\u{201E}x\u{201C}")
    }

    func testDecodeByteUndefinedIn1252FallsBackToLatin1() {
        // 0x81 has no Windows-1252 mapping → Latin-1, never a failure.
        XCTAssertEqual(decodeText(Data([0x41, 0x81, 0xF6])), "A\u{81}ö")
    }

    func testDecodeUTF16OnlyWithBOM() {
        XCTAssertEqual(decodeText(Data([0xFF, 0xFE, 0x41, 0x00])), "A")
        // Without a BOM the same bytes are UTF-8 "A\0", not CJK.
        XCTAssertEqual(decodeText(Data([0x41, 0x00])), "A\u{0}")
    }
}
