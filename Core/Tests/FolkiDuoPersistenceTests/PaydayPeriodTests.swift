import Foundation
import Testing
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor struct PaydayPeriodTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
    private let zone = "Europe/Moscow"

    private func open() async throws -> (BudgetRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolkiPayday-\(UUID())")
        return (try await BudgetRepository.open(directory: directory, localMemberID: UUID()), directory)
    }

    @Test func periodRunsFromTodayUntilPayday() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let payday = now.addingTimeInterval(10 * 86_400) // 29 October
        try repo.createPlan(monthlyPlan: Money(minorUnits: 1_000_000), available: Money(minorUnits: 1_000_000),
                            asOf: now, timeZone: zone, scope: .personal, payday: payday)
        let budget = try #require(try repo.load(asOf: now, scope: .personal))
        #expect(try budget.snapshot.period.remainingDays(including: now) == 10)
        // 10 000 ₽ over 10 days.
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now).todayGuide.minorUnits == 100_000)
        try repo.close()
    }

    @Test func earlySalaryClosesTheCurrentPeriod() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        try repo.createPlan(monthlyPlan: Money(minorUnits: 1_000_000), available: Money(minorUnits: 1_000_000),
                            asOf: now, timeZone: zone, scope: .personal, payday: now.addingTimeInterval(10 * 86_400))
        let later = now.addingTimeInterval(3 * 86_400)
        #expect(throws: LedgerError.existingPeriod) {
            try repo.createPlan(monthlyPlan: Money(minorUnits: 5_000_000), available: Money(minorUnits: 5_000_000),
                                asOf: later, timeZone: zone, scope: .personal, payday: later.addingTimeInterval(30 * 86_400))
        }
        try repo.createPlan(monthlyPlan: Money(minorUnits: 5_000_000), available: Money(minorUnits: 5_000_000),
                            asOf: later, timeZone: zone, scope: .personal, payday: later.addingTimeInterval(30 * 86_400), closeCurrent: true)
        let budget = try #require(try repo.load(asOf: later, scope: .personal))
        #expect(budget.snapshot.openingFunds.minorUnits == 5_000_000)
        #expect(try budget.snapshot.period.remainingDays(including: later) == 30)
        try repo.close()
    }
}
