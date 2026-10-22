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
        #expect(family.members.count == 1)
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
        // Household, the member and the period at least.
        #expect(visited.count >= 3)
        let forged = StoredBudget(snapshot: personal.snapshot, periodID: personal.periodID,
            members: personal.members, records: personal.records, scope: .family)
        #expect(throws: LedgerError.accessDenied) {
            try repo.save(entry(personal, author: author, amount: 100), in: forged, expectedRevision: nil, asOf: now)
        }
        try repo.close()
    }

}
