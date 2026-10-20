import Foundation
import Testing
import FolkiDuoCore

struct SpendingScheduleTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!; return calendar
    }
    @Test func defaultIncludesTheLastDayOfTheMonth() throws {
        let now = date("2026-10-20T12:00:00Z")
        let end = try SpendingSchedule.monthEnd.endExclusive(from: now, calendar: calendar)
        let period = try BudgetPeriod.untilPayday(from: now, payday: end, timeZoneIdentifier: calendar.timeZone.identifier)
        #expect(try period.remainingDays(including: now) == 12)
        #expect(end == date("2026-10-31T21:00:00Z"))
    }
    @Test func recurringDayIncludesTheChosenDayAndAdvancesAfterIt() throws {
        let now = date("2026-10-20T12:00:00Z")
        #expect(try SpendingSchedule.dayOfMonth(10).endExclusive(from: now, calendar: calendar) == date("2026-11-10T21:00:00Z"))
        #expect(try SpendingSchedule.dayOfMonth(20).endExclusive(from: now, calendar: calendar) == date("2026-10-20T21:00:00Z"))
    }
    @Test func shortMonthsClampTheDayAndInvalidDaysAreRejected() throws {
        let now = date("2026-02-20T12:00:00Z")
        #expect(try SpendingSchedule.dayOfMonth(31).endExclusive(from: now, calendar: calendar) == date("2026-02-28T21:00:00Z"))
        #expect(throws: BudgetError.invalidPeriod) { try SpendingSchedule.dayOfMonth(0).endExclusive(from: now, calendar: calendar) }
    }
}
