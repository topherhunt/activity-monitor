import Foundation
import JavaScriptCore
import Testing

/// Runs the picker's real script in JavaScriptCore, with no web view or window.
struct CalendarTests {
    let js = JSContext()!

    init() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Dayline/Resources/calendar.js")
        js.evaluateScript(try String(contentsOf: script, encoding: .utf8))
        #expect(js.exception == nil)
    }

    private func level(hours: Double) -> Int32 {
        js.evaluateScript("heatLevel(\(hours * 3600))").toInt32()
    }

    /// Nulls come back as "-" so a pad cell can't be mistaken for a day.
    private func cells(_ year: Int, _ month: Int) -> [String] {
        js.evaluateScript("monthCells(\(year), \(month)).map((d) => d === null ? '-' : String(d))")
            .toArray() as! [String]
    }

    @Test func nothingTrackedIsLevelZero() {
        #expect(level(hours: 0) == 0)
    }

    @Test func eachBandStartsAtItsBoundary() {
        #expect(level(hours: 0.01) == 1)
        #expect(level(hours: 2.99) == 1)
        #expect(level(hours: 3) == 2)
        #expect(level(hours: 5.99) == 2)
        #expect(level(hours: 6) == 3)
        #expect(level(hours: 9) == 4)
        #expect(level(hours: 12) == 5)
        #expect(level(hours: 16) == 5)
    }

    @Test func monthThatStartsOnSundayHasNoPadding() {
        let november = cells(2026, 10)
        #expect(november.first == "1")
        #expect(november.count == 30)
    }

    @Test func firstDayLandsUnderItsWeekday() {
        let august = cells(2026, 7)       // Aug 1 2026 is a Saturday
        #expect(august.prefix(7) == ["-", "-", "-", "-", "-", "-", "1"])
        #expect(august.last == "31")
    }

    @Test func februaryHandlesLeapYears() {
        #expect(cells(2026, 1).last == "28")
        #expect(cells(2028, 1).last == "29")
    }

    @Test func dayKeysArePadded() {
        #expect(js.evaluateScript("dayKey(2026, 0, 5)").toString() == "2026-01-05")
    }

    @Test func epochOfRollsOverIntoTheNextYear() {
        let expected = DateComponents(calendar: .current, year: 2027, month: 1, day: 1).date!
        #expect(js.evaluateScript("epochOf(2026, 12, 1)").toDouble() == expected.timeIntervalSince1970)
    }

    /// A 25-hour day: stepping by 86400 from Nov 1 lands at 11pm the same date.
    @Test func epochOfStaysAtMidnightAcrossDST() {
        let expected = DateComponents(calendar: .current, year: 2026, month: 11, day: 2).date!
        #expect(js.evaluateScript("epochOf(2026, 10, 2)").toDouble() == expected.timeIntervalSince1970)
    }
}
