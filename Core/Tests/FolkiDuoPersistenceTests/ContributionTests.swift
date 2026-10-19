import Foundation
import Testing
import CoreData
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor struct ContributionTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T09:00:00Z")!
    private func rub(_ n: Int64) -> Money { Money(minorUnits: n * 100) }
    private func path() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("FolkiContribution-\(UUID())") }
    private func budget(_ repo: BudgetRepository, _ scope: BudgetScope) throws -> StoredBudget {
        try #require(try repo.load(asOf: now, scope: scope))
    }
    private func open(_ directory: URL, author: UUID) async throws -> BudgetRepository {
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: author)
        if try repo.load(asOf: now, scope: .personal) == nil {
            try repo.createPlan(monthlyPlan: rub(30000), available: rub(30000), asOf: now, timeZone: "Europe/Moscow", scope: .personal)
            try repo.createPlan(monthlyPlan: rub(60000), available: rub(60000), asOf: now, timeZone: "Europe/Moscow", scope: .family)
        }
        return repo
    }

    @Test func contributionMovesMoneyWithoutCountingAsSpending() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID(), repo = try await open(directory, author: author)
        let link = UUID()
        try repo.contribute(rub(5000), from: budget(repo, .personal), to: budget(repo, .family), asOf: now, linkID: link)
        try repo.close()

        let reopened = try await BudgetRepository.open(directory: directory, localMemberID: author)
        let personal = try budget(reopened, .personal), family = try budget(reopened, .family)
        let own = try DailyBudgetCalculator.calculate(personal.snapshot, asOf: now)
        let shared = try DailyBudgetCalculator.calculate(family.snapshot, asOf: now)
        #expect(own.monthlyRemaining == rub(25000))
        #expect(shared.monthlyRemaining == rub(65000))
        #expect(own.todayNetSpending == rub(0))
        #expect(shared.todayNetSpending == rub(0))
        #expect(personal.records.map(\.transaction.kind) == [.contributionOut])
        #expect(family.records.map(\.transaction.kind) == [.contributionIn])
        #expect(personal.records.first?.linkID == link && family.records.first?.linkID == link)
        #expect(family.records.first?.transaction.payerID == author)

        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let month = try BudgetAnalytics.calculate(records: family.records, period: .month, anchor: now, asOf: now, calendar: calendar)
        #expect(month.expenses == rub(0))
        #expect(month.contributions == rub(5000))
        #expect(month.contributionsByMember.map(\.memberID) == [author])
        try reopened.close()
    }

    @Test func retryIsIdempotentAndCannotExceedPersonalMoney() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await open(directory, author: UUID())
        let link = UUID()
        try repo.contribute(rub(1000), from: budget(repo, .personal), to: budget(repo, .family), asOf: now, linkID: link)
        try repo.contribute(rub(1000), from: budget(repo, .personal), to: budget(repo, .family), asOf: now, linkID: link)
        #expect(try repo.history(scope: .personal).count == 1)
        #expect(try repo.history(scope: .family).count == 1)
        #expect(throws: LedgerError.conflict) {
            try repo.contribute(rub(2000), from: budget(repo, .personal), to: budget(repo, .family), asOf: now, linkID: link)
        }
        #expect(throws: BudgetError.insufficientReserve) {
            try repo.contribute(rub(29001), from: budget(repo, .personal), to: budget(repo, .family), asOf: now)
        }
        #expect(try repo.history(scope: .personal).count == 1)
        #expect(try repo.history(scope: .family).count == 1)
        try repo.close()
    }

    @Test func swappedBudgetsAndOrdinarySaveAreRejected() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID(), repo = try await open(directory, author: author)
        #expect(throws: LedgerError.accessDenied) {
            try repo.contribute(rub(100), from: budget(repo, .family), to: budget(repo, .personal), asOf: now)
        }
        let forged = LedgerRecord(transaction: TransactionSnapshot(amount: rub(100), kind: .contributionIn, date: now,
            authorID: author, payerID: author), title: "Взнос", linkID: UUID())
        #expect(throws: BudgetError.invalidTransaction) {
            try repo.save(forged, in: budget(repo, .family), expectedRevision: nil, asOf: now)
        }
        #expect(try repo.history(scope: .family).isEmpty)
        try repo.close()
    }

    @Test func cancellingRemovesBothSides() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await open(directory, author: UUID())
        let link = UUID()
        try repo.contribute(rub(3000), from: budget(repo, .personal), to: budget(repo, .family), asOf: now, linkID: link)
        try repo.cancelContribution(linkID: link, asOf: now)
        try repo.cancelContribution(linkID: link, asOf: now)
        #expect(try DailyBudgetCalculator.calculate(budget(repo, .personal).snapshot, asOf: now).monthlyRemaining == rub(30000))
        #expect(try DailyBudgetCalculator.calculate(budget(repo, .family).snapshot, asOf: now).monthlyRemaining == rub(60000))
        #expect(try repo.history(scope: .personal).allSatisfy(\.transaction.isDeleted))
        #expect(throws: LedgerError.missingRecord) { try repo.cancelContribution(linkID: UUID(), asOf: now) }
        try repo.close()
    }

    @Test func familyGraphNeverReferencesThePersonalSide() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await open(directory, author: UUID())
        let personal = try budget(repo, .personal)
        try repo.contribute(rub(500), from: personal, to: budget(repo, .family), asOf: now)
        let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        request.predicate = NSPredicate(format: "kind == %@", "contributionOut")
        let personalSide = try #require(try repo.container.viewContext.fetch(request).first)
        #expect(personalSide.objectID.persistentStore == repo.privateStore)
        #expect((personalSide.value(forKey: "household") as? NSManagedObject)?.value(forKey: "id") as? UUID == personal.snapshot.id)
        try repo.close()
    }
}
