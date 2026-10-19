import Foundation
import Testing
@testable import FolkiDuoCore

struct BudgetAnalyticsTests {
    private let author = UUID()
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/Moscow")!; return value
    }
    private func record(_ amount: Int64, kind: TransactionKind = .expense, date: Date, deleted: Bool = false,
                        funding: BudgetFunding = .flexible, category: ExpenseCategory = .groceries) -> LedgerRecord {
        LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: amount), kind: kind, funding: funding,
            date: date, authorID: author, payerID: author, isDeleted: deleted), title: "Запись", category: category)
    }
    @Test func separatesActualExpensesRefundsIncomeAndReserveTransfers() throws {
        let now = date("2026-10-19T12:00:00Z"), reserve = UUID()
        let records = [record(50000, date: now), record(20000, kind: .refund, date: now),
            record(100000, kind: .income, date: now, funding: .unallocated),
            record(30000, kind: .reserveAllocation, date: now, funding: .reserve(reserve)),
            record(5000, kind: .reserveRelease, date: now, funding: .reserve(reserve)),
            record(7000, date: now, funding: .reserve(reserve), category: .home)]
        let result = try BudgetAnalytics.calculate(records: records, period: .day, anchor: now, asOf: now, calendar: calendar)
        #expect(result.expenses.minorUnits == 57000)
        #expect(result.refunds.minorUnits == 20000)
        #expect(try result.netSpending.minorUnits == 37000)
        #expect(result.flexibleNetSpending.minorUnits == 30000)
        #expect(result.income.minorUnits == 100000)
        #expect(result.reserveTransfers.minorUnits == 25000)
        #expect(result.categories.count == 2)
    }
    @Test func historicalDayAndMondayWeekNeverIncludeLaterOrDeletedEntries() throws {
        let anchor = date("2026-10-20T12:00:00Z"), now = date("2026-10-23T12:00:00Z")
        let records = [record(100, date: date("2026-10-18T12:00:00Z")),
            record(200, date: date("2026-10-19T12:00:00Z")), record(300, date: date("2026-10-20T18:00:00Z")),
            record(400, date: date("2026-10-21T12:00:00Z")), record(900, date: anchor, deleted: true)]
        let week = try BudgetAnalytics.calculate(records: records, period: .week, anchor: anchor, asOf: now, calendar: calendar)
        #expect(week.expenses.minorUnits == 500)
        #expect(week.buckets.count == 7)
        #expect(week.buckets.filter(\.isObserved).count == 2)
        let day = try BudgetAnalytics.calculate(records: records, period: .day, anchor: anchor, asOf: now, calendar: calendar)
        #expect(day.expenses.minorUnits == 300)
        #expect(day.buckets.count == 24)
        let current = try BudgetAnalytics.calculate(records: records, period: .day, anchor: anchor, asOf: anchor, calendar: calendar)
        #expect(current.expenses.minorUnits == 0)
    }
    @Test func handlesMonthEdgesAndDSTWithoutAssuming86400SecondDays() throws {
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = date("2026-03-08T16:00:00Z"), autumn = date("2026-11-01T17:00:00Z")
        #expect(try BudgetAnalytics.calculate(records: [], period: .day, anchor: spring, asOf: spring, calendar: ny).buckets.count == 23)
        #expect(try BudgetAnalytics.calculate(records: [], period: .day, anchor: autumn, asOf: autumn, calendar: ny).buckets.count == 25)
        let month = try BudgetAnalytics.calculate(records: [record(100, date: date("2026-09-30T21:00:00Z"))],
            period: .month, anchor: date("2026-10-19T12:00:00Z"), asOf: date("2026-10-19T12:00:00Z"), calendar: calendar)
        #expect(month.buckets.count == 31)
        #expect(month.expenses.minorUnits == 100)
    }
    @Test func rejectsDuplicatesAndOverflowAndPreservesNegativeNetAfterRefunds() throws {
        let now = date("2026-10-19T12:00:00Z")
        let one = record(1, date: now)
        #expect(throws: BudgetError.duplicateIdentifier) {
            try BudgetAnalytics.calculate(records: [one, one], period: .month, anchor: now, asOf: now, calendar: calendar)
        }
        #expect(throws: BudgetError.amountOverflow) {
            try BudgetAnalytics.calculate(records: [record(.max, date: now), one], period: .day, anchor: now, asOf: now, calendar: calendar)
        }
        let refunded = try BudgetAnalytics.calculate(records: [record(100, kind: .refund, date: now)], period: .day, anchor: now, asOf: now, calendar: calendar)
        #expect(try refunded.netSpending.minorUnits == -100)
    }
    @Test(arguments: [(50000 as Int64, 150000 as Int64), (250000, -50000)])
    func dailyRemainingSubtractsFromTheOriginalGuide(spending: Int64, remaining: Int64) throws {
        let now = date("2026-10-17T12:00:00Z")
        let period = try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow")
        let snapshot = HouseholdSnapshot(period: period, monthlyFreePlan: Money(minorUnits: 3000000),
            openingFunds: Money(minorUnits: 3000000), transactions: [record(spending, date: now).transaction])
        let result = try DailyBudgetCalculator.calculate(snapshot, asOf: now)
        #expect(result.todayGuide.minorUnits == 200000)
        #expect(result.todayRemaining.minorUnits == remaining)
    }
}
