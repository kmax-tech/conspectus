import XCTest
@testable import ConspectusCore

final class TipsTests: XCTestCase {
    /// Fixed time zone so the day boundaries in these tests are the ones the
    /// assertions assume, whatever the machine is set to.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: iso)!
    }

    private let pool = [
        Tip(keys: "a", short: "one", long: "first"),
        Tip(keys: "b", short: "two", long: "second"),
        Tip(keys: "c", short: "three", long: "third"),
    ]

    // Same calendar day → same tip, whatever the hour.
    func testStableWithinADay() {
        let morning = tipOfTheDay(on: date("2026-08-17 00:01"), from: pool, calendar: calendar)
        let night = tipOfTheDay(on: date("2026-08-17 23:59"), from: pool, calendar: calendar)
        XCTAssertEqual(morning, night)
    }

    // Consecutive days step through the pool and wrap around.
    func testRotatesAndWraps() {
        let days = ["2026-08-17", "2026-08-18", "2026-08-19", "2026-08-20"]
            .map { tipOfTheDay(on: date($0 + " 12:00"), from: pool, calendar: calendar) }
        XCTAssertEqual(Set(days[0..<3].map { $0?.keys }).count, 3)  // all three, no repeat
        XCTAssertEqual(days[3], days[0])                            // wrapped after the pool
    }

    // Midnight in the calendar's zone is the flip, not midnight UTC.
    func testFlipsAtLocalMidnight() {
        let before = tipOfTheDay(on: date("2026-08-17 23:59"), from: pool, calendar: calendar)
        let after = tipOfTheDay(on: date("2026-08-18 00:01"), from: pool, calendar: calendar)
        XCTAssertNotEqual(before, after)
    }

    // Pre-epoch dates give a negative day number; the index must stay in range.
    func testPreEpochDateStaysInRange() {
        XCTAssertNotNil(tipOfTheDay(on: date("1969-07-20 20:17"), from: pool, calendar: calendar))
        XCTAssertNotNil(tipOfTheDay(on: date("1900-01-01 12:00"), from: pool, calendar: calendar))
    }

    // Empty pool: nothing to show, and no crash.
    func testEmptyPoolYieldsNil() {
        XCTAssertNil(tipOfTheDay(on: date("2026-08-17 12:00"), from: [], calendar: calendar))
    }

    // The shipped pool has to be usable in both places it is rendered.
    func testShippedTipsAreWellFormed() {
        XCTAssertFalse(conspectusTips.isEmpty)
        for tip in conspectusTips {
            XCTAssertFalse(tip.keys.isEmpty)
            XCTAssertFalse(tip.short.isEmpty)
            XCTAssertLessThanOrEqual(tip.short.count, 20, "bar label too long: \(tip.short)")
            XCTAssertGreaterThan(tip.long.count, tip.short.count, "no sentence for \(tip.keys)")
        }
    }
}
