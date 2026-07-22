import XCTest
@testable import ConspectusCore

/// Tests for the yazi keymap.toml subset parser (Keymap.swift).
final class KeymapTests: XCTestCase {
    /// Mirrors the structure of the user's real config: inline-table array,
    /// tabs, comments, single/array `on`, and triple-quoted multiline `run`
    /// containing brackets, braces, and quotes.
    private let inlineStyle = """
    [mgr]
    prepend_keymap = [
    \t# F1 opens help
    \t{ on = "<F1>", run = "help", desc = "Show keybindings help" },
    \t{ on = ["g", "p"], run = '''
    \t\tshell 'p="$(pbpaste)"; [ -e "$p" ] && ya emit reveal --str "$p"' --confirm
    \t''', desc = "Go to clipboard path" },
    \t{ on = "z", run = "plugin zoxide", desc = "Jump to a directory" },
    \t{ on = "=", run = '''
    \t\tshell '[ -n "$CONSPECTUS_PEER" ] && ya pub-to 0 panesync-cd --str "$PWD"'
    \t''', desc = "Sync: pull the other pane here" },
    ]
    """

    func testParsesInlineTableArrayStyle() throws {
        let b = try parseYaziKeymap(inlineStyle)
        XCTAssertEqual(b.count, 4)
        XCTAssertEqual(b[0], KeymapBinding(keys: ["<F1>"], desc: "Show keybindings help"))
        XCTAssertEqual(b[1].keys, ["g", "p"])
        XCTAssertEqual(b[1].desc, "Go to clipboard path")
        XCTAssertEqual(b[3].keys, ["="])
    }

    func testParsesArrayOfTablesStyle() throws {
        let toml = """
        [[mgr.prepend_keymap]]
        on = "!"
        run = "shell zsh --block"
        desc = "Drop to shell"

        [[mgr.prepend_keymap]]
        on = [ "c", "y" ]
        desc = "Copy file to clipboard"
        """
        let b = try parseYaziKeymap(toml)
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[0], KeymapBinding(keys: ["!"], desc: "Drop to shell"))
        XCTAssertEqual(b[1], KeymapBinding(keys: ["c", "y"], desc: "Copy file to clipboard"))
    }

    func testMissingDescFallsBackToCompactedRun() throws {
        let toml = """
        [mgr]
        prepend_keymap = [
        \t{ on = "q", run = '''
        \t\tquit
        \t\t--no-cwd-file
        \t''' },
        ]
        """
        let b = try parseYaziKeymap(toml)
        XCTAssertEqual(b[0].desc, "quit --no-cwd-file")   // one line, whitespace collapsed
    }

    func testOtherSectionsAreIgnored() throws {
        let toml = """
        [input]
        prepend_keymap = [ { on = "<Esc>", run = "close", desc = "input only" } ]

        [mgr]
        prepend_keymap = [ { on = "z", run = "plugin zoxide", desc = "jump" } ]
        """
        let b = try parseYaziKeymap(toml)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].keys, ["z"])
    }

    func testAppendKeymapIsCollectedToo() throws {
        let toml = """
        [mgr]
        append_keymap = [ { on = "M", run = "plugin mount", desc = "mount" } ]
        """
        XCTAssertEqual(try parseYaziKeymap(toml).count, 1)
    }

    func testMissingSectionThrows() {
        XCTAssertThrowsError(try parseYaziKeymap("[input]\nkeymap = []")) { error in
            XCTAssertEqual(error as? KeymapParseError, .missingSection("mgr"))
        }
    }

    func testEntryWithoutOnThrows() {
        let toml = """
        [mgr]
        prepend_keymap = [ { run = "help", desc = "no on key" } ]
        """
        XCTAssertThrowsError(try parseYaziKeymap(toml)) { error in
            XCTAssertEqual(error as? KeymapParseError, .entryWithoutOn(index: 0))
        }
    }

    func testUnterminatedStringThrows() {
        let toml = """
        [mgr]
        prepend_keymap = [ { on = "z, run = "oops" } ]
        """
        XCTAssertThrowsError(try parseYaziKeymap(toml))
    }

    func testSectionPresentButEmptyReturnsNoBindings() throws {
        XCTAssertEqual(try parseYaziKeymap("[mgr]\nprepend_keymap = []"), [])
    }
}
