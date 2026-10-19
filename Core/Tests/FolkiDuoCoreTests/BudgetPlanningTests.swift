import Foundation
import Testing
@testable import FolkiDuoCore

struct BudgetPlanningTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Moscow")!; return c }
    private func rub(_ n: Int64) -> Money { Money(minorUnits: n * 100) }
    @Test func forecastSeparatesExpectedCashAndNeverSubtractsProtectedPaymentsTwice() throws {
        let now = date("2026-10-19T09:00:00Z"), due = date("2026-10-25T00:00:00Z")
        let income = ExpectedIncomeSnapshot(id: UUID(), name: "Зарплата", amount: rub(20000), dueDate: due, revision: UUID())
        let reserved = ObligationSnapshot(id: UUID(), name: "Аренда", amount: rub(5000), dueDate: now, reserved: rub(5000), revision: UUID())
        let unpaid = ObligationSnapshot(id: UUID(), name: "Связь", amount: rub(600), dueDate: now, reserved: rub(0), revision: UUID())
        let plan = try BudgetPlanning.forecast(available: rub(6000), incomes: [income], obligations: [reserved, unpaid], asOf: now, calendar: calendar)
        #expect(plan.available == rub(6000))
        #expect(plan.unreservedPayments == rub(600))
        #expect(plan.beforeIncome == rub(5400))
        #expect(plan.dailyGuide == rub(900))
        #expect(plan.afterExpectedIncome == rub(25400))
        let deficit = try BudgetPlanning.forecast(available: rub(100), incomes: [], obligations: [unpaid], asOf: now, calendar: calendar)
        #expect(deficit.beforeIncome == rub(-500)); #expect(deficit.dailyGuide == rub(0))
    }
    @Test func contributionUsesDeadlineOrUserAmountWithCeilingAndTargetCap() throws {
        let now = date("2026-10-19T00:00:00Z"), deadline = date("2026-12-31T00:00:00Z")
        let goal = SavingsGoalSnapshot(id: UUID(), name: "Подушка", target: Money(minorUnits: 1000), balance: Money(minorUnits: 0), deadline: deadline)
        #expect(try BudgetPlanning.suggestedContribution(goal: goal, asOf: now, calendar: calendar)?.minorUnits == 334)
        let custom = SavingsGoalSnapshot(id: goal.id, name: goal.name, target: rub(1000), balance: rub(900), monthlyContribution: rub(300))
        #expect(try BudgetPlanning.suggestedContribution(goal: custom, asOf: now, calendar: calendar) == rub(100))
    }
    @Test func recurrenceRetainsOriginalMonthEndAndLeapDay() throws {
        let jan = date("2027-01-31T09:00:00Z")
        let feb = try #require(PaymentRecurrence.monthly.next(after: jan, calendar: calendar, anchor: jan))
        let mar = try #require(PaymentRecurrence.monthly.next(after: feb, calendar: calendar, anchor: jan))
        #expect(calendar.component(.day, from: feb) == 28)
        #expect(calendar.component(.day, from: mar) == 31)
        let leap = date("2024-02-29T09:00:00Z")
        let next = try #require(PaymentRecurrence.yearly.next(after: leap, calendar: calendar, anchor: leap))
        #expect(calendar.component(.day, from: next) == 28)
    }
    @Test func comparisonUsesPartialPreviousMonthAndWeekNotFullPeriod() throws {
        let author = UUID(), now = date("2026-10-19T09:00:00Z")
        func entry(_ n: Int64, _ date: Date) -> LedgerRecord { LedgerRecord(transaction: TransactionSnapshot(amount: rub(n), kind: .expense, date: date, authorID: author, payerID: author), title: "Трата") }
        let records = [entry(100, now), entry(70, date("2026-09-19T08:00:00Z")), entry(500, date("2026-09-19T10:00:00Z")), entry(900, date("2026-09-30T09:00:00Z"))]
        let result = try BudgetAnalytics.comparison(records: records, period: .month, anchor: now, asOf: now, calendar: calendar)
        #expect(result.current.expenses == rub(100)); #expect(result.previous.expenses == rub(70))
        #expect(try result.change == rub(30))
        let week = try BudgetAnalytics.comparison(records: [entry(30, date("2026-10-12T08:00:00Z")), entry(90, date("2026-10-13T08:00:00Z"))], period: .week, anchor: now, asOf: now, calendar: calendar)
        #expect(week.previous.expenses == rub(30))
    }
    @Test func shorterPreviousMonthCapsBothComparisonWindows() throws {
        let now = date("2026-10-31T09:00:00Z")
        let result = try BudgetAnalytics.comparison(records: [], period: .month, anchor: now, asOf: now, calendar: calendar)
        #expect(calendar.component(.day, from: result.current.cutoff) == 30)
        #expect(calendar.component(.day, from: result.previous.cutoff) == 30)
    }

}
