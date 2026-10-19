import Foundation
import Testing
@testable import FolkiDuoCore

struct ContributionCalculationTests {
    private let author = UUID()
    private let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
    private func rub(_ value: Int64) -> Money { Money(minorUnits: value * 100) }
    private func budget(scope: BudgetScope, records: [LedgerRecord] = []) throws -> StoredBudget {
        let period = try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow")
        let snapshot = HouseholdSnapshot(period: period, monthlyFreePlan: rub(15000), openingFunds: rub(15000),
            transactions: records.map(\.transaction))
        return StoredBudget(snapshot: snapshot, periodID: UUID(), members: [Member(id: author, name: "Я")], records: records, scope: scope)
    }
    private func contribution(_ kind: TransactionKind, _ amount: Int64, funding: BudgetFunding = .flexible) -> LedgerRecord {
        LedgerRecord(transaction: TransactionSnapshot(amount: rub(amount), kind: kind, funding: funding, date: now,
            authorID: author, payerID: author), title: "Взнос", linkID: UUID())
    }

    @Test func contributionChangesMonthAndTodayGuideButIsNotSpending() throws {
        // 15 days left in October from the 17th: 15 000 / 15 = 1 000 a day.
        let before = try DailyBudgetCalculator.calculate(budget(scope: .personal).snapshot, asOf: now)
        #expect(before.todayGuide == rub(1000))
        let out = try DailyBudgetCalculator.calculate(budget(scope: .personal, records: [contribution(.contributionOut, 1500)]).snapshot, asOf: now)
        #expect(out.monthlyRemaining == rub(13500))
        #expect(out.todayGuide == rub(900))
        #expect(out.todayNetSpending == rub(0))
        let into = try DailyBudgetCalculator.calculate(budget(scope: .family, records: [contribution(.contributionIn, 1500)]).snapshot, asOf: now)
        #expect(into.monthlyRemaining == rub(16500))
        #expect(into.todayGuide == rub(1100))
        #expect(into.todayNetSpending == rub(0))
    }

    @Test func contributionMustBeFlexibleLinkedAndMatchTheBudgetScope() throws {
        let personal = try budget(scope: .personal)
        _ = try LedgerRules.replacing(contribution(.contributionOut, 100), in: personal, asOf: now)
        #expect(throws: BudgetError.invalidTransaction) {
            try LedgerRules.replacing(contribution(.contributionIn, 100), in: personal, asOf: now)
        }
        let unlinked = LedgerRecord(transaction: TransactionSnapshot(amount: rub(100), kind: .contributionOut, date: now,
            authorID: author, payerID: author), title: "Взнос")
        #expect(throws: BudgetError.invalidTransaction) { try LedgerRules.replacing(unlinked, in: personal, asOf: now) }
        let linkedExpense = LedgerRecord(transaction: TransactionSnapshot(amount: rub(100), kind: .expense, date: now,
            authorID: author, payerID: author), title: "Покупка", linkID: UUID())
        #expect(throws: BudgetError.invalidTransaction) { try LedgerRules.replacing(linkedExpense, in: personal, asOf: now) }
        #expect(throws: BudgetError.invalidTransaction) {
            try LedgerRules.replacing(contribution(.contributionOut, 100, funding: .unallocated), in: personal, asOf: now)
        }
    }
}
