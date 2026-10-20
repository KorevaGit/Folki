import Foundation
import Testing
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor struct DailyStartTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
    private func rub(_ value: Int64) -> Money { Money(minorUnits: value * 100) }
    private func open() async throws -> (BudgetRepository, URL, UUID) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), author = UUID()
        return (try await BudgetRepository.open(directory: path, localMemberID: author), path, author)
    }
    private func start(_ repo: BudgetRepository) throws {
        let calendar = try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow").calendar
        try repo.createPlan(monthlyPlan: rub(0), available: rub(0), asOf: now, timeZone: "Europe/Moscow", scope: .personal,
                            payday: SpendingSchedule.monthEnd.endExclusive(from: now, calendar: calendar))
    }
    @Test func canRecordAnExpenseBeforeTheFirstDeposit() async throws {
        let (repo, path, author) = try await open(); defer { try? FileManager.default.removeItem(at: path) }
        try start(repo)
        let budget = try #require(try repo.load(asOf: now, scope: .personal))
        let expense = LedgerRecord(transaction: TransactionSnapshot(amount: rub(400), kind: .expense, date: now,
            authorID: author, payerID: author), title: "")
        try repo.save(expense, in: budget, expectedRevision: nil, asOf: now)
        let current = try #require(try repo.load(asOf: now, scope: .personal))
        #expect(try DailyBudgetCalculator.calculate(current.snapshot, asOf: now).todayRemaining == rub(-400))
        try repo.close()
    }
    @Test func repeatedDepositsGrowTheDailyBudgetWithoutDuplicatingRetries() async throws {
        let (repo, path, author) = try await open(); defer { try? FileManager.default.removeItem(at: path) }
        try start(repo)
        var budget = try #require(try repo.load(asOf: now, scope: .personal))
        let entry = LedgerRecord(transaction: TransactionSnapshot(amount: rub(18000), kind: .income, funding: .flexible,
            date: now, authorID: author, payerID: author), title: "")
        try repo.save(entry, in: budget, expectedRevision: nil, asOf: now, addIncomeToPlan: true)
        #expect(throws: LedgerError.conflict) { try repo.save(entry, in: budget, expectedRevision: nil, asOf: now, addIncomeToPlan: true) }
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        #expect(budget.snapshot.monthlyFreePlan == rub(18000))
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now).todayGuide == rub(1500))
        try repo.close()
    }
    @Test func fullFinanceUsesActualCashWithoutCountingTheDepositTwice() async throws {
        let (repo, path, author) = try await open(); defer { try? FileManager.default.removeItem(at: path) }
        try start(repo)
        var budget = try #require(try repo.load(asOf: now, scope: .personal))
        let income = LedgerRecord(transaction: TransactionSnapshot(amount: rub(18000), kind: .income, funding: .flexible,
            date: now, authorID: author, payerID: author), title: "")
        try repo.save(income, in: budget, expectedRevision: nil, asOf: now, addIncomeToPlan: true)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        let reserve = ProtectedReserve(name: "Жильё", openingAmount: rub(6000), isRegularPayment: true)
        try repo.updateSalaryPlan(available: rub(18000), reserves: [reserve], in: budget, asOf: now, balanceIsCurrent: true)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        let result = try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now)
        #expect(result.totalFunds == rub(18000))
        #expect(result.monthlyRemaining == rub(12000))
        #expect(result.todayGuide == rub(1000))
        #expect(budget.records.count == 1)
        try repo.close()
    }
    @Test func changingDistributionPreservesHistoryAndSurvivesReopening() async throws {
        let (repo, path, author) = try await open(); defer { try? FileManager.default.removeItem(at: path) }
        try start(repo)
        var budget = try #require(try repo.load(asOf: now, scope: .personal))
        let income = LedgerRecord(transaction: TransactionSnapshot(amount: rub(18000), kind: .income, funding: .flexible,
            date: now, authorID: author, payerID: author), title: "")
        try repo.save(income, in: budget, expectedRevision: nil, asOf: now, addIncomeToPlan: true)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        let end = try SpendingSchedule.dayOfMonth(10).endExclusive(from: now, calendar: budget.snapshot.period.calendar)
        try repo.updatePeriodEnd(end, in: budget, asOf: now)
        #expect(throws: LedgerError.conflict) { try repo.updatePeriodEnd(end, in: budget, asOf: now) }
        try repo.close()
        let reopened = try await BudgetRepository.open(directory: path, localMemberID: author)
        budget = try #require(try reopened.load(asOf: now, scope: .personal))
        #expect(budget.snapshot.period.endExclusive == end)
        #expect(budget.records.first?.id == income.id)
        #expect(try budget.snapshot.period.remainingDays(including: now) == 22)
        try reopened.close()
    }

    @Test func fullFinanceKeepsPastExpensesWhenSettingCurrentCash() async throws {
        let (repo, path, author) = try await open(); defer { try? FileManager.default.removeItem(at: path) }
        try start(repo)
        var budget = try #require(try repo.load(asOf: now, scope: .personal))
        let income = LedgerRecord(transaction: TransactionSnapshot(amount: rub(18000), kind: .income, funding: .flexible,
            date: now, authorID: author, payerID: author), title: "")
        try repo.save(income, in: budget, expectedRevision: nil, asOf: now, addIncomeToPlan: true)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        let expense = LedgerRecord(transaction: TransactionSnapshot(amount: rub(400), kind: .expense,
            date: now, authorID: author, payerID: author), title: "")
        try repo.save(expense, in: budget, expectedRevision: nil, asOf: now)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        try repo.updateSalaryPlan(available: rub(17600), reserves: [ProtectedReserve(name: "Жильё", openingAmount: rub(6000))],
                                  in: budget, asOf: now, balanceIsCurrent: true)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        let result = try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now)
        #expect(result.totalFunds == rub(17600))
        #expect(result.monthlyRemaining == rub(11600))
        #expect(budget.records.count == 2)
        try repo.close()
    }

    @Test func newPeriodCanCarryAnUnfundedExpenseDeficit() async throws {
        let (repo, path, _) = try await open(); defer { try? FileManager.default.removeItem(at: path) }
        let calendar = try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow").calendar
        try repo.createPlan(monthlyPlan: rub(0), available: rub(-400), asOf: now,
                            timeZone: "Europe/Moscow", scope: .personal,
                            payday: SpendingSchedule.monthEnd.endExclusive(from: now, calendar: calendar))
        let budget = try #require(try repo.load(asOf: now, scope: .personal))
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now).monthlyRemaining == rub(-400))
        try repo.close()
    }
}
