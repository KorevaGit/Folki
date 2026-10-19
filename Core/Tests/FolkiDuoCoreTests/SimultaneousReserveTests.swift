import Foundation
import Testing
@testable import FolkiDuoCore

struct SimultaneousReserveTests {
    @Test func simultaneousContributionPrecedesWithdrawalDespiteUUIDOrder() throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
        let member = UUID(), reserve = ProtectedReserve(name: "Цель", openingAmount: Money(minorUnits: 0))
        let deposit = TransactionSnapshot(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            amount: Money(minorUnits: 100000), kind: .reserveAllocation, funding: .reserve(reserve.id),
            date: date, authorID: member, payerID: member)
        let withdrawal = TransactionSnapshot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            amount: Money(minorUnits: 40000), kind: .reserveRelease, funding: .reserve(reserve.id),
            date: date, authorID: member, payerID: member)
        let period = try BudgetPeriod(monthContaining: date, timeZoneIdentifier: "Europe/Moscow")
        func calculate(_ transactions: [TransactionSnapshot]) throws -> DailyBudgetSnapshot {
            try DailyBudgetCalculator.calculate(HouseholdSnapshot(period: period,
                monthlyFreePlan: Money(minorUnits: 1000000), openingFunds: Money(minorUnits: 1000000),
                reserves: [reserve], transactions: transactions), asOf: date)
        }
        let result = try calculate([withdrawal, deposit])
        #expect(result.monthlyRemaining.minorUnits == 940000)
        #expect(result.todayNetSpending.minorUnits == 0)
        #expect(try calculate([deposit, withdrawal]) == result)
    }
}
