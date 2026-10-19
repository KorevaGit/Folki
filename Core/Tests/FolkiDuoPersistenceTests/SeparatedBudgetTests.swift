import Foundation
import Testing
import CoreData
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor
struct SeparatedBudgetTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
    private func rub(_ value: Int64) -> Money { Money(minorUnits: value * 100) }
    private func path() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("FolkiScopes-\(UUID())") }
    private func entry(_ budget: StoredBudget, author: UUID, amount: Int64) -> LedgerRecord {
        LedgerRecord(transaction: TransactionSnapshot(amount: rub(amount), kind: .expense, date: now,
            authorID: author, payerID: author), title: "Расход")
    }
    private func create(_ repo: BudgetRepository, scope: BudgetScope, amount: Int64 = 10000) throws -> StoredBudget {
        try repo.createPlan(monthlyPlan: rub(amount), available: rub(amount), asOf: now,
            timeZone: "Europe/Moscow", scope: scope)
        return try #require(try repo.load(asOf: now, scope: scope))
    }

    @Test func personalAndFamilyOperationsAndLimitsAreIndependentAfterReopen() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID()
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: author)
        let personal = try create(repo, scope: .personal, amount: 30000)
        let family = try create(repo, scope: .family, amount: 120000)
        #expect(personal.members.count == 1)
        #expect(family.members.count == 2)
        #expect(personal.snapshot.id != family.snapshot.id)
        try repo.save(entry(personal, author: author, amount: 1000), in: personal, expectedRevision: nil, asOf: now)
        try repo.save(entry(family, author: author, amount: 2330), in: family, expectedRevision: nil, asOf: now)
        try repo.close()
        let reopened = try await BudgetRepository.open(directory: directory, localMemberID: author)
        let a = try #require(try reopened.load(asOf: now, scope: .personal))
        let b = try #require(try reopened.load(asOf: now, scope: .family))
        let own = try DailyBudgetCalculator.calculate(a.snapshot, asOf: now)
        let shared = try DailyBudgetCalculator.calculate(b.snapshot, asOf: now)
        #expect(own.monthlyRemaining == rub(29000))
        #expect(shared.monthlyRemaining == rub(117670))
        #expect(own.todayRemaining == rub(1000))
        #expect(shared.todayRemaining == rub(5670))
        #expect(try reopened.history(scope: .personal).count == 1)
        #expect(try reopened.history(scope: .family).count == 1)
        try reopened.close()
    }

    @Test func sharingRejectsPersonalRootAndFamilyGraphCannotReachIt() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID()
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: author)
        let personal = try create(repo, scope: .personal)
        let family = try create(repo, scope: .family)
        try repo.createGoal(name: "Личное", target: rub(5000), in: personal, asOf: now)
        #expect(throws: LedgerError.privateBudgetCannotBeShared) {
            try repo.sharingRootID(householdID: personal.snapshot.id)
        }
        let rootID = try repo.sharingRootID(householdID: family.snapshot.id)
        let root = try repo.container.viewContext.existingObject(with: rootID)
        var queue = [root]
        var visited = Set<NSManagedObjectID>()
        while let object = queue.popLast() {
            guard visited.insert(object.objectID).inserted else { continue }
            #expect(object.value(forKey: "id") as? UUID != personal.snapshot.id)
            for relationship in object.entity.relationshipsByName.values {
                if let child = object.value(forKey: relationship.name) as? NSManagedObject { queue.append(child) }
                if let children = object.value(forKey: relationship.name) as? Set<NSManagedObject> { queue.append(contentsOf: children) }
            }
        }
        #expect(visited.count >= 4)
        let forged = StoredBudget(snapshot: personal.snapshot, periodID: personal.periodID,
            members: personal.members, records: personal.records, scope: .family)
        #expect(throws: LedgerError.accessDenied) {
            try repo.save(entry(personal, author: author, amount: 100), in: forged, expectedRevision: nil, asOf: now)
        }
        try repo.close()
    }

    @Test func savingsAreScopedAtomicAndNeverChargedTwice() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID()
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: author)
        var personal = try create(repo, scope: .personal)
        _ = try create(repo, scope: .family)
        try repo.createGoal(name: "Моя цель", target: rub(50000), in: personal, asOf: now)
        personal = try #require(try repo.load(asOf: now, scope: .personal))
        let goal = try #require(try repo.goals(scope: .personal, asOf: now).first)
        let operation = UUID()
        try repo.transferToGoal(goal.id, amount: rub(1000), withdrawal: false, in: personal, asOf: now, operationID: operation)
        try repo.transferToGoal(goal.id, amount: rub(1000), withdrawal: false, in: personal, asOf: now, operationID: operation)
        personal = try #require(try repo.load(asOf: now, scope: .personal))
        var result = try DailyBudgetCalculator.calculate(personal.snapshot, asOf: now)
        #expect(result.monthlyRemaining == rub(9000))
        #expect(result.todayNetSpending == rub(0))
        #expect(try repo.goals(scope: .personal, asOf: now).first?.balance == rub(1000))
        #expect(try repo.goals(scope: .family, asOf: now).isEmpty == true)
        try repo.transferToGoal(goal.id, amount: rub(400), withdrawal: true, in: personal, asOf: now)
        personal = try #require(try repo.load(asOf: now, scope: .personal))
        result = try DailyBudgetCalculator.calculate(personal.snapshot, asOf: now)
        #expect(result.monthlyRemaining == rub(9400))
        #expect(personal.records.count == 2)
        #expect(try repo.goals(scope: .personal, asOf: now).first?.balance == rub(600))
        #expect(throws: BudgetError.insufficientReserve) {
            try repo.transferToGoal(goal.id, amount: rub(601), withdrawal: true, in: personal, asOf: now)
        }
        #expect(throws: BudgetError.insufficientReserve) {
            try repo.transferToGoal(goal.id, amount: rub(9401), withdrawal: false, in: personal, asOf: now)
        }
        #expect(try repo.history(scope: .personal).count == 2)
        let family = try #require(try repo.load(asOf: now, scope: .family))
        #expect(try DailyBudgetCalculator.calculate(family.snapshot, asOf: now).monthlyRemaining == rub(10000))
        try repo.createGoal(name: "Общая цель", target: rub(20000), in: family, asOf: now)
        let sharedGoal = try #require(try repo.goals(scope: .family, asOf: now).first)
        try repo.transferToGoal(sharedGoal.id, amount: rub(2000), withdrawal: false, in: family, asOf: now)
        let sharedAfter = try #require(try repo.load(asOf: now, scope: .family))
        #expect(try DailyBudgetCalculator.calculate(sharedAfter.snapshot, asOf: now).monthlyRemaining == rub(8000))
        #expect(try repo.goals(scope: .personal, asOf: now).first?.balance == rub(600))
        #expect(try repo.goals(scope: .family, asOf: now).first?.balance == rub(2000))
        try repo.close()
        let reopened = try await BudgetRepository.open(directory: directory, localMemberID: author)
        #expect(try reopened.goals(scope: .personal, asOf: now).first?.balance == rub(600))
        let november = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        try reopened.createPlan(monthlyPlan: rub(20000), available: rub(20000), asOf: november, scope: .personal)
        let next = try #require(try reopened.load(asOf: november, scope: .personal))
        #expect(try DailyBudgetCalculator.calculate(next.snapshot, asOf: november).monthlyRemaining == rub(19400))
        try reopened.transferToGoal(goal.id, amount: rub(100), withdrawal: true, in: next, asOf: november)
        #expect(try reopened.goals(scope: .personal, asOf: november).first?.balance == rub(500))
        try reopened.close()
    }

    @Test func incompleteSavingsImportCannotShowUnprotectedFreeMoney() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID()
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: author)
        var budget = try create(repo, scope: .personal)
        try repo.createGoal(name: "Цель", target: rub(5000), in: budget, asOf: now)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        let goal = try #require(try repo.goals(scope: .personal, asOf: now).first)
        try repo.transferToGoal(goal.id, amount: rub(1000), withdrawal: false, in: budget, asOf: now)
        let request = NSFetchRequest<NSManagedObject>(entityName: "GoalContribution")
        let contribution = try #require(try repo.container.viewContext.fetch(request).first)
        repo.container.viewContext.delete(contribution)
        try repo.container.viewContext.save()
        #expect(throws: LedgerError.corruptStore) { try repo.load(asOf: now, scope: .personal) }
        #expect(throws: LedgerError.corruptStore) { try repo.goals(scope: .personal, asOf: now) }
        try repo.close()
    }
}
