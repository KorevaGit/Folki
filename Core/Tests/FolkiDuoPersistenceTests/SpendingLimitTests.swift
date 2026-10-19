import Foundation
import Testing
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor struct SpendingLimitTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
    @Test func limitsPersistIndependentlyWithoutCreatingFundsOrChangingRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolkiLimits-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let member = UUID()
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: member)
        for scope in BudgetScope.allCases {
            try repo.createPlan(monthlyPlan: Money(minorUnits: 6000000), available: Money(minorUnits: 3000000),
                asOf: now, timeZone: "Europe/Moscow", scope: scope)
        }
        let personal = try #require(try repo.load(asOf: now, scope: .personal))
        let entry = LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 50000), kind: .expense,
            date: now, authorID: member, payerID: member), title: "Расход")
        try repo.save(entry, in: personal, expectedRevision: nil, asOf: now)
        try repo.updateSpendingLimit(Money(minorUnits: 4000000), in: personal, asOf: now)
        #expect(throws: LedgerError.conflict) { try repo.updateSpendingLimit(Money(minorUnits: 3500000), in: personal, asOf: now) }
        try repo.close()
        let reopened = try await BudgetRepository.open(directory: directory, localMemberID: member)
        let own = try #require(try reopened.load(asOf: now, scope: .personal))
        let family = try #require(try reopened.load(asOf: now, scope: .family))
        #expect(own.snapshot.monthlyFreePlan.minorUnits == 4000000)
        #expect(family.snapshot.monthlyFreePlan.minorUnits == 6000000)
        #expect(own.snapshot.openingFunds.minorUnits == 3000000)
        #expect(own.records.map(\.id) == [entry.id])
        #expect(try DailyBudgetCalculator.calculate(own.snapshot, asOf: now).monthlyRemaining.minorUnits == 2950000)
        let forged = StoredBudget(snapshot: own.snapshot, periodID: own.periodID, members: own.members, records: own.records, scope: .family)
        #expect(throws: LedgerError.accessDenied) { try reopened.updateSpendingLimit(Money(minorUnits: 100000), in: forged, asOf: now) }
        #expect(throws: BudgetError.invalidPlan) { try reopened.updateSpendingLimit(Money(minorUnits: 0), in: own, asOf: now) }
        try reopened.close()
    }
}
