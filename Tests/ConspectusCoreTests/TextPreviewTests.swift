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
}
