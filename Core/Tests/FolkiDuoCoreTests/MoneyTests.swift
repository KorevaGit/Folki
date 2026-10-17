import Foundation
import Testing
@testable import FolkiDuoCore

struct MoneyTests {
    @Test(arguments: [
        ("1 670,50", Int64(167050)), ("1\u{00a0}670.50", 167050),
        ("1\u{202f}670", 167000), (" 0,01 ", 1), ("-0,01", -1), ("+25", 2500),
        ("92233720368547758.07", Int64.max), ("-92233720368547758.08", Int64.min)
    ])
    func parsesLocalizedAmounts(value: String, expected: Int64) throws {
        #expect(try Money(parsing: value).minorUnits == expected)
    }

    @Test(arguments: ["", "1 67", "1.234", "1,2,3", "2 ₽", "12abc", "NaN", "1e3", ".5", "--2", "92233720368547758.08"])
    func rejectsInvalidOrOverflowedAmounts(_ input: String) {
        #expect(throws: (any Error).self) { try Money(parsing: input) }
    }

    @Test func arithmeticNeverWraps() {
        #expect(throws: BudgetError.amountOverflow) {
            try Money(minorUnits: .max).adding(Money(minorUnits: 1))
        }
        #expect(throws: BudgetError.amountOverflow) {
            try Money(minorUnits: .min).subtracting(Money(minorUnits: 1))
        }
    }

    @Test func currencyAndPrecisionAreExplicit() throws {
        let yen = try Currency(code: "JPY", fractionDigits: 0)
        #expect(try Money(parsing: "125", currency: yen).minorUnits == 125)
        #expect(throws: BudgetError.invalidAmount) { try Money(parsing: "1.5", currency: yen) }
        #expect(throws: BudgetError.currencyMismatch) {
            try Money(minorUnits: 100).adding(Money(minorUnits: 100, currency: yen))
        }
        #expect(throws: BudgetError.invalidCurrency) { try Currency(code: "rub", fractionDigits: 2) }
    }

    @Test(arguments: [1, 2, 7, 28, 31])
    func dailyAllocationPreservesEveryMinorUnit(days: Int) throws {
        for amount: Int64 in [0, 1, 2, 100, 101, 4_155_000, Int64.max] {
            let allocation = try DailyAllocation(total: Money(minorUnits: amount), days: days)
            var sum: Int64 = 0
            for day in 0..<days { sum += try allocation.amount(forDay: day).minorUnits }
            #expect(sum == amount)
            #expect(allocation.extraUnitDays < days)
        }
    }

    @Test func distributionIsStableAcrossDays() throws {
        let allocation = try DailyAllocation(total: Money(minorUnits: 301), days: 3)
        #expect(try allocation.amount(forDay: 0).minorUnits == 101)
        #expect(try allocation.amount(forDay: 1).minorUnits == 100)
        #expect(try allocation.amount(forDay: 2).minorUnits == 100)
        #expect(throws: BudgetError.invalidDayCount) { try allocation.amount(forDay: 3) }
        #expect(throws: BudgetError.invalidDayCount) { try DailyAllocation(total: Money(minorUnits: 1), days: 0) }
    }
}
