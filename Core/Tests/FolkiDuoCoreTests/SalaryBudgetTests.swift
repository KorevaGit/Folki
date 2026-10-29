import Foundation
import Testing
import FolkiDuoCore

struct SalaryBudgetTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
    private let member = UUID()
    private func rub(_ value: Int64) -> Money { Money(minorUnits: value * 100) }
    private func snapshot(_ entries: [TransactionSnapshot] = [], payments: [ProtectedReserve]) throws -> HouseholdSnapshot {
        HouseholdSnapshot(period: try BudgetPeriod.untilPayday(from: now, payday: now.addingTimeInterval(10 * 86400),
            timeZoneIdentifier: "Europe/Moscow"), monthlyFreePlan: rub(5000), openingFunds: rub(10000), reserves: payments, transactions: entries)
    }
    @Test func paymentChangesOnlyPeriodRingAndRefundRestoresIt() throws {
        let rent = ProtectedReserve(name: "Аренда", openingAmount: rub(3000), isRegularPayment: true)
        let savings = ProtectedReserve(name: "Копилка", openingAmount: rub(2000))
        let payment = TransactionSnapshot(amount: rub(1000), kind: .expense, funding: .reserve(rent.id), date: now, authorID: member, payerID: member)
        let refund = TransactionSnapshot(amount: rub(300), kind: .refund, funding: .reserve(rent.id), date: now.addingTimeInterval(1), authorID: member, payerID: member)
        let before = try DailyBudgetCalculator.calculate(snapshot(payments: [rent, savings]), asOf: now)
        let after = try DailyBudgetCalculator.calculate(snapshot([payment], payments: [rent, savings]), asOf: now)
        let returned = try DailyBudgetCalculator.calculate(snapshot([payment, refund], payments: [rent, savings]), asOf: now.addingTimeInterval(1))
        #expect(before.periodPlan == rub(8000))
        #expect(before.periodRemaining == rub(8000))
        #expect(after.periodRemaining == rub(7000))
        #expect(returned.periodRemaining == rub(7300))
        #expect(after.todayRemaining == before.todayRemaining)
        #expect(after.todayGuide == rub(500))
        #expect(after.monthlyRemaining == before.monthlyRemaining)
        #expect(after.futureAllocation == before.futureAllocation)
        #expect(after.monthRingFraction == 0.875)
        #expect(after.reserveBalances[rent.id] == rub(2000))
    }
    @Test func allFundsCanBeReservedWithoutDivisionByZero() throws {
        let reserve = ProtectedReserve(name: "Платёж", openingAmount: rub(1000), isRegularPayment: true)
        let period = try BudgetPeriod.untilPayday(from: now, payday: now.addingTimeInterval(86400), timeZoneIdentifier: "Europe/Moscow")
        let result = try DailyBudgetCalculator.calculate(HouseholdSnapshot(period: period, monthlyFreePlan: rub(0),
            openingFunds: rub(1000), reserves: [reserve]), asOf: now)
        #expect(result.dayRingFraction == 0)
        #expect(result.monthRingFraction == 1)
        #expect(result.todayRemaining == rub(0))
    }
    @Test func closingAtNoonStillLeavesOneObservedDay() throws {
        let period = try BudgetPeriod(start: now.addingTimeInterval(-2 * 86400), endExclusive: now, timeZoneIdentifier: "Europe/Moscow")
        #expect(try period.remainingDays(including: now.addingTimeInterval(-1)) == 1)
        #expect(try period.remainingDays(including: period.start) == 3)
    }
    @Test func analyticsUsesPaydayBoundsAcrossCalendarMonths() throws {
        let start = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-11-10T21:00:00Z")!
        let period = try BudgetPeriod(start: start, endExclusive: end, timeZoneIdentifier: "Europe/Moscow")
        let dates = [start.addingTimeInterval(-1), start, start.addingTimeInterval(12 * 86400), end]
        let records = dates.map { LedgerRecord(transaction: TransactionSnapshot(amount: rub(100), kind: .expense,
            date: $0, authorID: member, payerID: member), title: "") }
        let result = try BudgetAnalytics.calculate(records: records, period: .month, anchor: end.addingTimeInterval(-1),
            asOf: end, calendar: period.calendar, budgetPeriod: period)
        #expect(result.interval.start == start)
        #expect(result.interval.end == end)
        #expect(result.expenses == rub(200))
        #expect(result.buckets.count == 22)
        #expect(result.buckets.reduce(0) { $0 + $1.expenses.minorUnits } == 20000)
    }
    @Test func paydayDaysRespectDST() throws {
        let start = ISO8601DateFormatter().date(from: "2026-10-31T16:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-11-03T16:00:00Z")!
        let period = try BudgetPeriod.untilPayday(from: start, payday: end, timeZoneIdentifier: "America/New_York")
        #expect(try period.remainingDays(including: start) == 3)
    }
}
