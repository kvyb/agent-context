import XCTest
@testable import AboutTimeCLI

final class MemoryQueryScopeParserTests: XCTestCase {
    private var calendar: Calendar!
    private var parser: MemoryQueryScopeParser!

    override func setUp() {
        super.setUp()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        parser = MemoryQueryScopeParser(calendar: calendar)
    }

    func testInferTodayScope() {
        let reference = date(year: 2026, month: 3, day: 12, hour: 9)
        let scope = parser.inferScope(for: "what did I do today", referenceDate: reference)
        XCTAssertEqual(scope.label, "today")
        XCTAssertEqual(scope.start, date(year: 2026, month: 3, day: 12))
        XCTAssertEqual(scope.end, date(year: 2026, month: 3, day: 13))
    }

    func testInferThisWeekScopeStartsMonday() {
        let reference = date(year: 2026, month: 3, day: 12, hour: 9)
        let scope = parser.inferScope(for: "status this week", referenceDate: reference)
        XCTAssertEqual(scope.label, "this week")
        XCTAssertEqual(scope.start, date(year: 2026, month: 3, day: 9))
        XCTAssertEqual(scope.end, date(year: 2026, month: 3, day: 16))
    }

    func testInferWeekdayScope() {
        let reference = date(year: 2026, month: 3, day: 12, hour: 9)
        let scope = parser.inferScope(for: "what did I do on monday", referenceDate: reference)
        XCTAssertEqual(scope.label, "monday")
        XCTAssertEqual(scope.start, date(year: 2026, month: 3, day: 9))
        XCTAssertEqual(scope.end, date(year: 2026, month: 3, day: 10))
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}
