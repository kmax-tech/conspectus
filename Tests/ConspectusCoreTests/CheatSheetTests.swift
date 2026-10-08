import XCTest
@testable import ConspectusCore

final class CheatSheetTests: XCTestCase {
    private let groups: [CheatSheetGroup] = [
        CheatSheetGroup("Find", [("g s", "Search: names into listing (fd)"),
                                 ("g i", "indago: indexed corpus search")]),
        CheatSheetGroup("conspectus", [("⌘D", "toggle split pane"),
                                       ("g f", "follow symlink to the real file"),
                                       ("", "  the link's relative target may dangle"),
                                       ("⌘K", "this cheat sheet")]),
    ]

    func testEmptyQueryKeepsEverything() {
        XCTAssertEqual(filterCheatSheet(groups, query: ""), groups)
        XCTAssertEqual(filterCheatSheet(groups, query: "   "), groups)
    }

    func testMatchesDescription() {
        let hits = filterCheatSheet(groups, query: "indago")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].title, "Find")
        XCTAssertEqual(hits[0].entries, [CheatSheetEntry("g i", "indago: indexed corpus search")])
    }

    func testMatchesKeyIncludingSpacedChords() {
        XCTAssertEqual(filterCheatSheet(groups, query: "g s").first?.entries.count, 1)
        XCTAssertEqual(filterCheatSheet(groups, query: "⌘K").first?.entries,
                       [CheatSheetEntry("⌘K", "this cheat sheet")])
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(filterCheatSheet(groups, query: "INDAGO").first?.title, "Find")
    }

    func testContinuationLinesTravelWithTheirEntry() {
        // Hit on the keyed line: its continuation comes along.
        let byKey = filterCheatSheet(groups, query: "symlink")
        XCTAssertEqual(byKey.first?.entries.map(\.key), ["g f", ""])
        // Hit on the continuation line: the keyed line above comes along,
        // otherwise the explanation would show without its key.
        let byContinuation = filterCheatSheet(groups, query: "dangle")
        XCTAssertEqual(byContinuation.first?.entries.map(\.key), ["g f", ""])
    }

    func testMatchingTitleKeepsWholeGroup() {
        let hits = filterCheatSheet(groups, query: "conspectus")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].entries.count, 4)
    }

    func testNoMatchYieldsNoGroups() {
        XCTAssertEqual(filterCheatSheet(groups, query: "zzz"), [])
    }

    func testShortcutCountIgnoresContinuationLines() {
        XCTAssertEqual(cheatSheetShortcutCount(groups), 5)
        XCTAssertEqual(cheatSheetShortcutCount(filterCheatSheet(groups, query: "symlink")), 1)
    }

    func testBlocksStartWithLeadingContinuationLines() {
        // A group that opens with an unkeyed line must not lose it.
        let blocks = cheatSheetBlocks([CheatSheetEntry("", "note"), CheatSheetEntry("a", "add")])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], [CheatSheetEntry("", "note")])
    }
}

// MARK: - shadowing by the user's keymap.toml

extension CheatSheetTests {
    /// A rebound key loses its built-in line — otherwise "g i" shows twice.
    func testShadowedEntryDrops() {
        let groups = [CheatSheetGroup("Find", [("/", "find"), ("g i", "indago: indexed corpus search")])]
        let out = dropShadowedEntries(groups, boundBy: [KeymapBinding(keys: ["g", "i"], desc: "indago")])
        XCTAssertEqual(out, [CheatSheetGroup("Find", [("/", "find")])])
    }

    /// Alternatives go together only if the user rebound all of them.
    func testAlternativesNeedAllBound() {
        let groups = [CheatSheetGroup("Files", [("o / Enter", "open"), ("s / S", "fzf picker")])]
        let out = dropShadowedEntries(groups, boundBy: [KeymapBinding(keys: ["o"], desc: "open"),
                                                        KeymapBinding(keys: ["<Enter>"], desc: "open"),
                                                        KeymapBinding(keys: ["s"], desc: "search")])
        XCTAssertEqual(out, [CheatSheetGroup("Files", [("s / S", "fzf picker")])])
    }

    /// Continuation lines belong to their entry and leave with it.
    func testShadowingTakesContinuationLines() {
        let groups = [CheatSheetGroup("Find", [("g i", "indago"), ("", "…indexed corpus search"),
                                               ("n / N", "next / previous")])]
        let out = dropShadowedEntries(groups, boundBy: [KeymapBinding(keys: ["g", "i"], desc: "indago")])
        XCTAssertEqual(out, [CheatSheetGroup("Find", [("n / N", "next / previous")])])
    }

    /// An emptied group disappears; ⌘-keys and unbound defaults stay.
    func testEmptyGroupDropsAndConspectusKeysSurvive() {
        let groups = [CheatSheetGroup("Find", [("s", "fzf picker")]),
                      CheatSheetGroup("conspectus", [("⌘D", "toggle split pane")])]
        let out = dropShadowedEntries(groups, boundBy: [KeymapBinding(keys: ["s"], desc: "search")])
        XCTAssertEqual(out, [CheatSheetGroup("conspectus", [("⌘D", "toggle split pane")])])
    }

    /// Case matters for single characters, not for named keys or arrows.
    func testKeyNormalization() {
        XCTAssertEqual(normalizedKeySequence(["<Enter>"]), normalizedKeySequence(["Enter"]))
        XCTAssertEqual(normalizedKeySequence(["→"]), normalizedKeySequence(["<Right>"]))
        XCTAssertNotEqual(normalizedKeySequence(["s"]), normalizedKeySequence(["S"]))
        XCTAssertEqual(normalizedKeySequence(["g", "i"]), "g i")
    }

    /// No bindings, no change.
    func testNoBindingsKeepsGroups() {
        let groups = [CheatSheetGroup("Find", [("g i", "indago")])]
        XCTAssertEqual(dropShadowedEntries(groups, boundBy: []), groups)
    }
}
