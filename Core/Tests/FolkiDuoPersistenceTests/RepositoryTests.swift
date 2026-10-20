import Foundation
import Testing
import CoreData
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor
struct RepositoryTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
    private func open(_ directory: URL, _ member: UUID) async throws -> BudgetRepository {
        try await BudgetRepository.open(directory: directory, localMemberID: member)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("FolkiTests-\(UUID())") }
    private func rub(_ amount: Int64) -> Money { Money(minorUnits: amount * 100) }
    private func record(_ budget: StoredBudget, author: UUID, amount: Int64 = 1000,
                        kind: TransactionKind = .expense, funding: BudgetFunding = .flexible,
                        date: Date? = nil, old: LedgerRecord? = nil, deleted: Bool = false) -> LedgerRecord {
        LedgerRecord(transaction: TransactionSnapshot(id: old?.id ?? UUID(), amount: rub(amount), kind: kind,
            funding: funding, date: date ?? now, authorID: old?.transaction.authorID ?? author,
            payerID: budget.members.first(where: { $0.id != author })!.id, isDeleted: deleted), title: "Покупка", categoryID: BuiltInCategory.groceries.id)
    }
    private func setup(_ repo: BudgetRepository) throws -> StoredBudget {
        try repo.createPlan(monthlyPlan: rub(120000), available: rub(41550), asOf: now, timeZone: "Europe/Moscow")
        return try #require(try repo.load(asOf: now))
    }

    @Test func sqliteSurvivesCloseAndReopenWithStableIdentity() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let member = UUID()
        let first = try await open(path, member)
        let initial = try setup(first)
        let entry = record(initial, author: member)
        try first.save(entry, in: initial, expectedRevision: nil, asOf: now)
        try first.close()
        let second = try await open(path, member)
        let loaded = try #require(try second.load(asOf: now))
        #expect(loaded.snapshot.id == initial.snapshot.id)
        #expect(loaded.periodID == initial.periodID)
        #expect(loaded.members == initial.members)
        #expect(try second.authorID(in: loaded) == member)
        #expect(loaded.records.count == 1)
        #expect(loaded.records[0].categoryID == BuiltInCategory.groceries.id)
        #expect(loaded.records[0].transaction.payerID != member)
        #expect(try DailyBudgetCalculator.calculate(loaded.snapshot, asOf: now).monthlyRemaining == rub(40550))
        try second.close()
    }

    @Test func editRefundDeleteRestoreAndPreviewUseExactlyOneOperation() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let member = UUID(); let repo = try await open(path, member)
        var budget = try setup(repo)
        let expense = record(budget, author: member, amount: 2330)
        try repo.save(expense, in: budget, expectedRevision: nil, asOf: now)
        budget = try #require(try repo.load(asOf: now))
        let edit = record(budget, author: member, amount: 1670, old: expense)
        let preview = try DailyBudgetCalculator.calculate(LedgerRules.replacing(edit, in: budget, asOf: now).snapshot, asOf: now)
        #expect(try repo.load(asOf: now)?.records.first?.transaction.amount == rub(2330))
        try repo.save(edit, in: budget, expectedRevision: expense.revision, asOf: now)
        budget = try #require(try repo.load(asOf: now))
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now) == preview)
        let refund = record(budget, author: member, amount: 200, kind: .refund)
        try repo.save(refund, in: budget, expectedRevision: nil, asOf: now)
        budget = try #require(try repo.load(asOf: now))
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now).monthlyRemaining == rub(40080))
        let deleted = record(budget, author: member, amount: 1670, old: edit, deleted: true)
        try repo.save(deleted, in: budget, expectedRevision: edit.revision, asOf: now)
        budget = try #require(try repo.load(asOf: now))
        #expect(budget.records.count == 2)
        let afterDeletion = try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now)
        #expect(afterDeletion.monthlyRemaining.minorUnits == 4_175_000)
        #expect(budget.records.first(where: { $0.id == deleted.id })?.transaction.isDeleted == true)
        let restored = record(budget, author: member, amount: 1670, old: deleted)
        try repo.save(restored, in: budget, expectedRevision: deleted.revision, asOf: now)
        budget = try #require(try repo.load(asOf: now))
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now).monthlyRemaining == rub(40080))
        try repo.close()
    }

    @Test func staleEditorAndRetryCannotDuplicateOrOverwrite() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let member = UUID(); let repo = try await open(path, member)
        var budget = try setup(repo)
        let entry = record(budget, author: member)
        try repo.save(entry, in: budget, expectedRevision: nil, asOf: now)
        #expect(throws: LedgerError.conflict) { try repo.save(entry, in: budget, expectedRevision: nil, asOf: now) }
        budget = try #require(try repo.load(asOf: now))
        let edit = record(budget, author: member, amount: 500, old: entry)
        try repo.save(edit, in: budget, expectedRevision: entry.revision, asOf: now)
        let stale = record(budget, author: member, amount: 900, old: entry)
        #expect(throws: LedgerError.conflict) { try repo.save(stale, in: budget, expectedRevision: entry.revision, asOf: now) }
        let actual = try #require(try repo.load(asOf: now))
        #expect(actual.records.count == 1)
        #expect(actual.records[0].transaction.amount == rub(500))
        try repo.close()
    }

    @Test func dateMoveRecomputesGuideAndIncomeNeedsExplicitAssignment() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let member = UUID(); let repo = try await open(path, member)
        var budget = try setup(repo)
        let expense = record(budget, author: member, amount: 1050)
        try repo.save(expense, in: budget, expectedRevision: nil, asOf: now)
        budget = try #require(try repo.load(asOf: now))
        let moved = record(budget, author: member, amount: 1050, date: now.addingTimeInterval(-86400), old: expense)
        try repo.save(moved, in: budget, expectedRevision: expense.revision, asOf: now)
        budget = try #require(try repo.load(asOf: now))
        let baseline = try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now)
        #expect(baseline.todayGuide == rub(2700))
        let income = record(budget, author: member, amount: 10000, kind: .income, funding: .unallocated)
        try repo.save(income, in: budget, expectedRevision: nil, asOf: now)
        budget = try #require(try repo.load(asOf: now))
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now).monthlyRemaining == baseline.monthlyRemaining)
        let assigned = record(budget, author: member, amount: 10000, kind: .income, funding: .flexible, old: income)
        try repo.save(assigned, in: budget, expectedRevision: income.revision, asOf: now)
        budget = try #require(try repo.load(asOf: now))
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now).monthlyRemaining == rub(50500))
        try repo.close()
    }

    @Test func validationFailuresLeaveNoPartialChanges() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let member = UUID(); let repo = try await open(path, member)
        let budget = try setup(repo)
        let future = record(budget, author: member, date: now.addingTimeInterval(86400))
        #expect(throws: BudgetError.invalidTransaction) { try repo.save(future, in: budget, expectedRevision: nil, asOf: now) }
        #expect(throws: LedgerError.existingPeriod) { _ = try setup(repo) }
        #expect(try repo.load(asOf: now)?.records.isEmpty == true)
        #expect(throws: LedgerError.invalidMember) {
            try repo.save(record(budget, author: UUID()), in: budget, expectedRevision: nil, asOf: now)
        }
        try repo.close()
    }

    @Test func newMonthPreservesArchivedPeriodAndHousehold() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let member = UUID(); let repo = try await open(path, member)
        let october = try setup(repo)
        let entry = record(october, author: member)
        try repo.save(entry, in: october, expectedRevision: nil, asOf: now)
        let novemberDate = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        try repo.createPlan(monthlyPlan: rub(50000), available: rub(50000), asOf: novemberDate)
        let november = try #require(try repo.load(asOf: novemberDate))
        #expect(november.snapshot.id == october.snapshot.id)
        #expect(november.periodID != october.periodID)
        #expect(november.records.isEmpty)
        #expect(try repo.load(asOf: now)?.records.count == 1)
        #expect(try repo.history().count == 1)
        let archived = try #require(try repo.load(asOf: now))
        let corrected = record(archived, author: member, amount: 500, old: entry)
        try repo.save(corrected, in: archived, expectedRevision: entry.revision,
                      asOf: october.snapshot.period.endExclusive.addingTimeInterval(-1))
        let unchangedNovember = try #require(try repo.load(asOf: novemberDate))
        #expect(try DailyBudgetCalculator.calculate(unchangedNovember.snapshot, asOf: novemberDate).monthlyRemaining == rub(50000))
        #expect(try repo.history().first?.transaction.amount == rub(500))
        try repo.close()
    }

    @Test func reservedPaymentAndRefundSurviveReopenWithoutSecondCharge() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let member = UUID(); let repo = try await open(path, member)
        let reserve = ProtectedReserve(name: "Аренда", openingAmount: rub(20000))
        try repo.createPlan(monthlyPlan: rub(120000), available: rub(61550), asOf: now,
                            timeZone: "Europe/Moscow", reserves: [reserve])
        var budget = try #require(try repo.load(asOf: now))
        let payment = record(budget, author: member, amount: 20000, funding: .reserve(reserve.id))
        try repo.save(payment, in: budget, expectedRevision: nil, asOf: now)
        budget = try #require(try repo.load(asOf: now))
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now).monthlyRemaining == rub(41550))
        let excessive = record(budget, author: member, amount: 1, funding: .reserve(reserve.id))
        #expect(throws: BudgetError.insufficientReserve) {
            try repo.save(excessive, in: budget, expectedRevision: nil, asOf: now)
        }
        try repo.close()
        let reopened = try await open(path, member)
        budget = try #require(try reopened.load(asOf: now))
        #expect(budget.snapshot.reserves[0].id == reserve.id)
        #expect(budget.records.count == 1)
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now).monthlyRemaining == rub(41550))
        try reopened.close()
    }

    @Test func independentWritersPreserveEachOthersOperations() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let member = UUID(); let first = try await open(path, member)
        let original = try setup(first)
        let second = try await open(path, member)
        let a = record(original, author: member, amount: 1050)
        let b = record(original, author: member, amount: 620)
        try first.save(a, in: original, expectedRevision: nil, asOf: now)
        // An independently opened writer still sees the new operation when validating its save.
        try second.save(b, in: original, expectedRevision: nil, asOf: now)
        try first.close(); try second.close()
        let reopened = try await open(path, member)
        let loaded = try #require(try reopened.load(asOf: now))
        #expect(Set(loaded.records.map(\.id)) == Set([a.id, b.id]))
        #expect(try DailyBudgetCalculator.calculate(loaded.snapshot, asOf: now).monthlyRemaining == rub(39880))
        try reopened.close()
    }

    @Test func currentModelHasCloudCompatibleRelationshipsAndNoCounters() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let repo = try await open(path, UUID())
        let model = repo.container.managedObjectModel
        #expect(Set(model.entities.compactMap(\.name)) == ["Household", "Member", "BudgetPeriod", "Transaction", "Reserve", "Category", "Envelope"])
        #expect(model.versionIdentifiers.contains(AnyHashable("1")))
        for entity in model.entities {
            #expect(entity.uniquenessConstraints.isEmpty)
            for relationship in entity.relationshipsByName.values {
                #expect(relationship.isOptional)
                #expect(relationship.inverseRelationship != nil)
            }
            #expect(entity.attributesByName["monthlyRemaining"] == nil)
        }
        try repo.close()
    }
}
