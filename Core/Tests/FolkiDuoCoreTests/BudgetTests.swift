import Foundation
import Testing
@testable import FolkiDuoCore

private let member = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private let now = instant("2026-10-17T12:00:00Z")
private func rub(_ amount: Int64) -> Money { Money(minorUnits: amount * 100) }
private func entry(_ amount: Int64, kind: TransactionKind = .expense, funding: BudgetFunding = .flexible,
                   date: Date = now, id: UUID = UUID(), deleted: Bool = false) -> TransactionSnapshot {
    TransactionSnapshot(id: id, amount: rub(amount), kind: kind, funding: funding, date: date,
                        authorID: member, payerID: member, isDeleted: deleted)
}
private func household(_ entries: [TransactionSnapshot] = [], opening: Int64 = 120000,
                       reserves: [ProtectedReserve] = [], at date: Date = now) throws -> HouseholdSnapshot {
    HouseholdSnapshot(period: try BudgetPeriod(monthContaining: date, timeZoneIdentifier: "Europe/Moscow"),
                      monthlyFreePlan: rub(120000), openingFunds: rub(opening), reserves: reserves, transactions: entries)
}
private func baseline() throws -> HouseholdSnapshot {
    try household([entry(78450, date: instant("2026-10-16T10:00:00Z")), entry(1050), entry(620)])
}

struct BudgetTests {
    @Test func referenceScenarioDrivesBothRings() throws {
        let result = try DailyBudgetCalculator.calculate(baseline(), asOf: now)
        #expect(result.remainingDays == 15)
        #expect(result.todayGuide == rub(2770))
        #expect(result.todayRemaining == rub(1100))
        #expect(result.todayNetSpending == rub(1670))
        #expect(result.monthlyRemaining == rub(39880))
        #expect(abs(result.dayRingFraction - 1100.0 / 2770) < 0.000001)
        #expect(abs(result.monthRingFraction - 39880.0 / 120000) < 0.000001)
        #expect(result.futureAllocation?.firstDayAmount.minorUnits == 284858)
    }

    @Test func purchasePreviewDoesNotCreateASecondCharge() throws {
        let original = try baseline()
        let result = try DailyBudgetCalculator.calculate(original, asOf: now)
        let preview = try PurchaseImpactCalculator.preview(amount: rub(2330), against: result)
        let recorded = try DailyBudgetCalculator.calculate(household(original.transactions + [entry(2330)]), asOf: now)
        #expect(preview.todayRemaining == rub(-1230))
        #expect(preview.monthlyRemaining == rub(37550))
        #expect(preview.futureAllocation?.firstDayAmount.minorUnits == 268215)
        #expect(recorded.todayRemaining == preview.todayRemaining)
        #expect(recorded.monthlyRemaining == preview.monthlyRemaining)
        #expect(recorded.dayRingFraction == 0)
        #expect(recorded.todayOverspending == rub(1230))
        #expect(original.transactions.count == 3)
    }

    @Test func guideDoesNotMoveAfterOrdinaryPurchases() throws {
        let before = try DailyBudgetCalculator.calculate(household([entry(78450, date: instant("2026-10-16T10:00:00Z"))]), asOf: now)
        let after = try DailyBudgetCalculator.calculate(baseline(), asOf: now)
        #expect(before.todayGuide == after.todayGuide)
    }

    @Test func unspentMoneyRollsIntoTheNextDay() throws {
        let nextDay = instant("2026-10-18T12:00:00Z")
        let result = try DailyBudgetCalculator.calculate(baseline(), asOf: nextDay)
        #expect(result.todayNetSpending == rub(0))
        #expect(result.todayGuide.minorUnits == 284858)
        #expect(result.todayRemaining == result.todayGuide)
    }

    @Test func lastDayHasNoFutureDivision() throws {
        let date = instant("2026-10-31T12:00:00Z")
        let snapshot = try household([entry(39000, date: instant("2026-10-30T12:00:00Z"))], opening: 41550)
        let result = try DailyBudgetCalculator.calculate(snapshot, asOf: date)
        #expect(result.remainingDays == 1)
        #expect(result.todayGuide == rub(2550))
        #expect(result.futureAllocation == nil)
        #expect(try PurchaseImpactCalculator.preview(amount: rub(3000), against: result).futureAllocation == nil)
    }

    @Test func payingAProtectedBillDoesNotReduceFreeMoneyTwice() throws {
        let reserve = ProtectedReserve(name: "Аренда", openingAmount: rub(20000))
        let before = try DailyBudgetCalculator.calculate(household(opening: 61550, reserves: [reserve]), asOf: now)
        let after = try DailyBudgetCalculator.calculate(household([entry(20000, funding: .reserve(reserve.id))], opening: 61550, reserves: [reserve]), asOf: now)
        #expect(before.monthlyRemaining == rub(41550))
        #expect(before.monthlyRemaining == after.monthlyRemaining)
        #expect(before.todayGuide == after.todayGuide)
        #expect(after.todayNetSpending == rub(0))
    }

    @Test func cannotSpendMoreThanTheProtectedReserve() throws {
        let reserve = ProtectedReserve(name: "Счёт", openingAmount: rub(1000))
        #expect(throws: BudgetError.insufficientReserve) {
            try DailyBudgetCalculator.calculate(household([entry(1001, funding: .reserve(reserve.id))], reserves: [reserve]), asOf: now)
        }
    }

    @Test func explicitReserveTransferAndReleaseAreNotExpenses() throws {
        let reserve = ProtectedReserve(name: "Цель", openingAmount: rub(0))
        let result = try DailyBudgetCalculator.calculate(household([
            entry(5000, kind: .reserveAllocation, funding: .reserve(reserve.id), date: now.addingTimeInterval(-60)),
            entry(1000, kind: .reserveRelease, funding: .reserve(reserve.id))
        ], opening: 41550, reserves: [reserve]), asOf: now)
        #expect(result.monthlyRemaining == rub(37550))
        #expect(result.todayNetSpending == rub(0))
        #expect(result.todayGuide.minorUnits == 250334)
    }

    @Test func incomeRequiresExplicitBudgetAssignment() throws {
        let initial = try DailyBudgetCalculator.calculate(household(opening: 41550), asOf: now)
        let unallocated = try DailyBudgetCalculator.calculate(household([entry(10000, kind: .income, funding: .unallocated)], opening: 41550), asOf: now)
        let assigned = try DailyBudgetCalculator.calculate(household([entry(10000, kind: .income, funding: .flexible)], opening: 41550), asOf: now)
        #expect(initial.monthlyRemaining == unallocated.monthlyRemaining)
        #expect(initial.todayGuide == unallocated.todayGuide)
        #expect(assigned.monthlyRemaining == rub(51550))
        #expect(assigned.todayNetSpending == rub(0))
        let defaultIncome = TransactionSnapshot(amount: rub(10000), kind: .income, date: now, authorID: member, payerID: member)
        #expect(defaultIncome.funding == .unallocated)
    }

    @Test func refundsAndEditsRecalculateTheSourceSnapshot() throws {
        let items = try baseline().transactions
        let result = try DailyBudgetCalculator.calculate(household(items + [entry(200, kind: .refund)]), asOf: now)
        #expect(result.todayGuide == rub(2770))
        #expect(result.todayRemaining == rub(1300))
        #expect(result.monthlyRemaining == rub(40080))
        let deleted = try DailyBudgetCalculator.calculate(household([items[0], entry(1050, deleted: true), items[2]]), asOf: now)
        #expect(deleted.todayRemaining == rub(2150))
        let moved = try DailyBudgetCalculator.calculate(household([items[0], entry(1050, date: instant("2026-10-16T12:00:00Z")), items[2]]), asOf: now)
        #expect(moved.monthlyRemaining == rub(39880))
        #expect(moved.todayGuide == rub(2700))
    }

    @Test func futureAndOtherPeriodEntriesDoNotAffectCurrentBudget() throws {
        let result = try DailyBudgetCalculator.calculate(household([
            entry(999, date: instant("2026-09-30T12:00:00Z")),
            entry(999, date: instant("2026-10-18T12:00:00Z")),
            entry(999, date: instant("2026-11-01T12:00:00Z"))
        ], opening: 41550), asOf: now)
        #expect(result.todayGuide == rub(2770))
        #expect(result.monthlyRemaining == rub(41550))
    }

    @Test func deficitsNeverBecomePositiveSpendingPermission() throws {
        let result = try DailyBudgetCalculator.calculate(household([entry(2000)], opening: 1000), asOf: now)
        #expect(result.monthlyRemaining == rub(-1000))
        #expect(result.monthRingFraction == 0)
        #expect(result.futureAllocation?.firstDayAmount == rub(0))
        let obligations = [ProtectedReserve(name: "Платежи", openingAmount: rub(2000))]
        let overcommitted = try DailyBudgetCalculator.calculate(household(opening: 1000, reserves: obligations), asOf: now)
        #expect(overcommitted.todayGuide == rub(0))
        #expect(overcommitted.monthlyRemaining == rub(-1000))
    }

    @Test func rejectsDuplicatedOrInvalidLedgerEntries() throws {
        let transaction = entry(100)
        #expect(throws: BudgetError.duplicateIdentifier) {
            try DailyBudgetCalculator.calculate(household([transaction, transaction]), asOf: now)
        }
        #expect(throws: BudgetError.invalidTransaction) {
            try DailyBudgetCalculator.calculate(household([entry(0)]), asOf: now)
        }
        #expect(throws: BudgetError.missingReserve) {
            try DailyBudgetCalculator.calculate(household([entry(1, funding: .reserve(UUID()))]), asOf: now)
        }
    }

    @Test func rejectsInvalidPreviewAmounts() throws {
        let result = try DailyBudgetCalculator.calculate(baseline(), asOf: now)
        #expect(throws: BudgetError.invalidAmount) { try PurchaseImpactCalculator.preview(amount: rub(0), against: result) }
    }

    @Test func previewRejectsUnrecordableAggregateOverflow() throws {
        let transaction = TransactionSnapshot(amount: Money(minorUnits: .max), kind: .expense,
            date: now, authorID: member, payerID: member)
        let snapshot = HouseholdSnapshot(period: try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow"),
            monthlyFreePlan: rub(1), openingFunds: rub(0), transactions: [transaction])
        let result = try DailyBudgetCalculator.calculate(snapshot, asOf: now)
        #expect(result.todayOverspending.minorUnits == Int64.max)
        #expect(throws: BudgetError.amountOverflow) {
            try PurchaseImpactCalculator.preview(amount: Money(minorUnits: 1), against: result)
        }
    }

    @Test func validatesPlanReservesAndCurrencyBeforeReturningResults() throws {
        let period = try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow")
        #expect(throws: BudgetError.invalidPlan) {
            try DailyBudgetCalculator.calculate(HouseholdSnapshot(period: period, monthlyFreePlan: rub(0), openingFunds: rub(1)), asOf: now)
        }
        let reserve = ProtectedReserve(name: "Счёт", openingAmount: rub(100))
        #expect(throws: BudgetError.duplicateIdentifier) {
            try DailyBudgetCalculator.calculate(household(reserves: [reserve, reserve]), asOf: now)
        }
        let other = try Currency(code: "USD", fractionDigits: 2)
        let foreign = TransactionSnapshot(amount: Money(minorUnits: 100, currency: other), kind: .expense,
            date: now, authorID: member, payerID: member)
        #expect(throws: BudgetError.currencyMismatch) {
            try DailyBudgetCalculator.calculate(household([foreign]), asOf: now)
        }
        #expect(throws: BudgetError.invalidAmount) {
            try GoalContribution(goalID: UUID(), memberID: member, amount: rub(0), direction: .contribution, date: now)
        }
    }

    @Test func independentOfflinePurchasesDoNotDependOnInputOrdering() throws {
        let snapshot = try baseline()
        let expected = try DailyBudgetCalculator.calculate(snapshot, asOf: now)
        let reordered = try household(snapshot.transactions.reversed())
        #expect(try DailyBudgetCalculator.calculate(reordered, asOf: now) == expected)
    }
}

struct PeriodTests {
    @Test(arguments: [
        ("2024-02-28T12:00:00Z", "Europe/Moscow", 2),
        ("2026-02-28T12:00:00Z", "Europe/Moscow", 1),
        ("2026-03-08T16:00:00Z", "America/New_York", 24),
        ("2026-10-31T22:30:00Z", "America/New_York", 1),
        ("2026-10-31T22:30:00Z", "Europe/Moscow", 30)
    ])
    func calendarDaysUseHouseholdZone(date: String, zone: String, days: Int) throws {
        let value = instant(date)
        let period = try BudgetPeriodResolver.month(containing: value, timeZoneIdentifier: zone)
        #expect(try period.remainingDays(including: value) == days)
    }

    @Test func rejectsInvalidTimeZoneAndOutOfPeriodDate() throws {
        #expect(throws: BudgetError.invalidTimeZone) { try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "invalid") }
        let period = try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow")
        #expect(!period.contains(period.endExclusive))
        #expect(throws: BudgetError.dateOutsidePeriod) { try period.remainingDays(including: period.endExclusive) }
    }
}
