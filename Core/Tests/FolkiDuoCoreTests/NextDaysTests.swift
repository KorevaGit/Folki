import Foundation
import Testing
@testable import FolkiDuoCore

struct NextDaysTests {
    private let author = UUID()
    private let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
    private func rub(_ value: Int64) -> Money { Money(minorUnits: value * 100) }
    private func snapshot(_ records: [TransactionSnapshot]) throws -> DailyBudgetSnapshot {
        let period = try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow")
        // 11 days left from the 21st: 11 000 / 11 = 1 000 a day.
        return try DailyBudgetCalculator.calculate(HouseholdSnapshot(period: period, monthlyFreePlan: rub(11000),
            openingFunds: rub(11000), transactions: records), asOf: now)
    }
    private func entry(_ amount: Int64, _ kind: TransactionKind = .expense) -> TransactionSnapshot {
        TransactionSnapshot(amount: rub(amount), kind: kind, funding: .flexible, date: now, authorID: author, payerID: author)
    }

    @Test func aPurchaseCostsItsAmountSpreadOverTheRemainingDays() throws {
        // Before: 11 000 over the 10 days after today if nothing more is spent today.
        let before = try snapshot([])
        #expect(before.futureAllocation?.firstDayAmount == rub(1100))
        let after = try snapshot([entry(500)])
        #expect(try after.nextDaysChange(since: before) == rub(-50))
        #expect(after.futureAllocation?.firstDayAmount == rub(1050))
    }

    @Test func eachPurchaseIsMeasuredFromTheForecastBeforeIt() throws {
        // Already over today's guide: the next purchase still costs only its own share.
        let before = try snapshot([entry(1500)])
        #expect(try snapshot([entry(1500), entry(500)]).nextDaysChange(since: before) == rub(-50))
        #expect(try snapshot([entry(1500), entry(1100, .income)]).nextDaysChange(since: before) == rub(110))
        #expect(try before.nextDaysChange(since: before) == rub(0))
    }

    @Test func roundingDownNeverOverstatesWhatIsLeft() {
        #expect(Money(minorUnits: 192_308).roundedDownToWholeUnits == Money(minorUnits: 192_300))
        #expect(Money(minorUnits: -49_950).roundedDownToWholeUnits == Money(minorUnits: -50_000))
        #expect(Money(minorUnits: -50_000).roundedDownToWholeUnits == Money(minorUnits: -50_000))
        #expect(Money(minorUnits: 0).roundedDownToWholeUnits == Money(minorUnits: 0))
        #expect(Money(minorUnits: 319_950).roundedUpToWholeUnits == Money(minorUnits: 320_000))
        #expect(Money(minorUnits: 320_000).roundedUpToWholeUnits == Money(minorUnits: 320_000))
    }
}
