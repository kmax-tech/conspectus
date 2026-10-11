import XCTest
@testable import ConspectusCore

final class RethemeTests: XCTestCase {

    func testNoAnswerYet() {
        XCTAssertEqual(rethemeWaitSummary(pending: ["L"], refusals: [:]), "re-theming yazi…")
    }

    func testTasksOnly() {
        XCTAssertEqual(rethemeWaitSummary(pending: ["L"], refusals: ["L": "tasks"]),
                       "yazi re-theme waits for file tasks")
    }

    func testBothReasonsAcrossPanes() {
        XCTAssertEqual(rethemeWaitSummary(pending: ["L", "R"], refusals: ["L": "tasks", "R": "selection"]),
                       "yazi re-theme waits for file tasks and the selection to clear")
    }

    func testRefusalOfARelaunchedPaneIsIgnored() {
        // R already relaunched (no longer pending) — its old reason must not linger.
        XCTAssertEqual(rethemeWaitSummary(pending: ["L"], refusals: ["L": "selection", "R": "tasks"]),
                       "yazi re-theme waits for the selection to clear")
    }

    func testUnknownReasonShownVerbatim() {
        XCTAssertEqual(rethemeWaitSummary(pending: ["L"], refusals: ["L": "input"]),
                       "yazi re-theme waits for input")
    }
}
