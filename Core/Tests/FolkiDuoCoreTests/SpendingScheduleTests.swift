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
    @Test func aWeekStaysAWeekWhenExtended() throws {
        let rule = PeriodRule.days(7)
        let start = date("2026-10-21T12:00:00Z")
        let first = try rule.end(after: start, now: start, calendar: calendar)
        #expect(first == date("2026-10-27T21:00:00Z"))
        // Opened again four days after the week ended: the next week keeps the same weekday, not "today + 7".
        #expect(try rule.end(after: first, now: date("2026-11-01T09:00:00Z"), calendar: calendar) == date("2026-11-03T21:00:00Z"))
        // Away for longer than a whole week: skip to the week that covers today.
        #expect(try rule.end(after: first, now: date("2026-11-05T09:00:00Z"), calendar: calendar) == date("2026-11-10T21:00:00Z"))
        #expect(throws: BudgetError.invalidPeriod) { try PeriodRule.days(0).end(after: start, now: start, calendar: calendar) }
    }
    @Test func aMonthAndAPaydayRepeatOnTheSameDate() throws {
        let start = date("2026-10-21T12:00:00Z")
        let month = PeriodRule.monthly(startingOn: start, calendar: calendar)
        #expect(month == .dayOfMonth(20))
        let first = try month.end(after: start, now: start, calendar: calendar)
        #expect(first == date("2026-11-20T21:00:00Z"))
        #expect(try month.end(after: first, now: date("2026-11-21T09:00:00Z"), calendar: calendar) == date("2026-12-20T21:00:00Z"))
        #expect(PeriodRule.monthly(startingOn: date("2026-11-01T09:00:00Z"), calendar: calendar) == .monthEnd)
        // Payday on the 10th: the 10th opens the next period.
        let payday = PeriodRule.payday(date("2026-11-10T09:00:00Z"), calendar: calendar)
        #expect(try payday.end(after: date("2026-11-09T21:00:00Z"), now: date("2026-11-10T09:00:00Z"), calendar: calendar)
                == date("2026-12-09T21:00:00Z"))
    }
    @Test func oldBudgetsKeepTheCadenceOfTheirCurrentPeriod() throws {
        let zone = "Europe/Moscow"
        // Onboarding "Месяц" before the rule was stored: 21 October up to and including 19 November.
        let thirtyDays = try BudgetPeriod(start: date("2026-10-20T21:00:00Z"), endExclusive: date("2026-11-19T21:00:00Z"), timeZoneIdentifier: zone)
        #expect(PeriodRule.inferred(from: thirtyDays) == .dayOfMonth(19))
        let week = try BudgetPeriod(start: date("2026-10-20T21:00:00Z"), endExclusive: date("2026-10-27T21:00:00Z"), timeZoneIdentifier: zone)
        #expect(PeriodRule.inferred(from: week) == .days(7))
        let month = try BudgetPeriod(monthContaining: date("2026-10-21T12:00:00Z"), timeZoneIdentifier: zone)
        #expect(PeriodRule.inferred(from: month) == .monthEnd)
        let toMonthEnd = try BudgetPeriod(start: date("2026-10-20T21:00:00Z"), endExclusive: date("2026-10-31T21:00:00Z"), timeZoneIdentifier: zone)
        #expect(PeriodRule.inferred(from: toMonthEnd) == .monthEnd)
    }
    @Test func periodRulesSurviveStorageAndRejectUnknownValues() {
        for rule in [PeriodRule.monthEnd, .dayOfMonth(9), .days(7), .days(14)] {
            #expect(PeriodRule(storageValue: rule.storageValue) == rule)
        }
        #expect(PeriodRule(storageValue: "fortnight") == nil)
        #expect(PeriodRule(storageValue: "day:40") == nil)
        #expect(PeriodRule(storageValue: "days:0") == nil)
    }
    @Test func shortMonthsClampTheDayAndInvalidDaysAreRejected() throws {
        let now = date("2026-02-20T12:00:00Z")
        #expect(try SpendingSchedule.dayOfMonth(31).endExclusive(from: now, calendar: calendar) == date("2026-02-28T21:00:00Z"))
        #expect(throws: BudgetError.invalidPeriod) { try SpendingSchedule.dayOfMonth(0).endExclusive(from: now, calendar: calendar) }
    }
}
