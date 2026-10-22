import Foundation
import Testing
import CoreData
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor struct FamilyPeriodTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z")!
    private func rub(_ value: Int64) -> Money { Money(minorUnits: value * 100) }
    private func open() async throws -> (BudgetRepository, URL, UUID) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("FolkiFamily-\(UUID())"), author = UUID()
        return (try await BudgetRepository.open(directory: path, localMemberID: author), path, author)
    }

    @Test func aFollowingPeriodStartsWhereThePreviousEnded() async throws {
        let (repo, path, _) = try await open(); defer { try? FileManager.default.removeItem(at: path) }
        let previousEnd = ISO8601DateFormatter().date(from: "2026-11-19T21:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-12-19T21:00:00Z")!
        // Opened three days after the period ended: the new one still starts on the 20th.
        try repo.createPlan(monthlyPlan: rub(0), available: rub(0), asOf: now, timeZone: "Europe/Moscow",
                            scope: .family, payday: end, startingAt: previousEnd)
        let budget = try #require(try repo.load(asOf: now, scope: .family))
        #expect(budget.snapshot.period.start == previousEnd)
        #expect(budget.snapshot.period.endExclusive == end)
        try repo.close()
    }

    @Test func duplicatePeriodsFromTwoDevicesMergeIntoOne() async throws {
        let (repo, path, author) = try await open(); defer { try? FileManager.default.removeItem(at: path) }
        let start = ISO8601DateFormatter().date(from: "2026-11-19T21:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-12-19T21:00:00Z")!
        let rent = ProtectedReserve(name: "Аренда", openingAmount: rub(5000), isRegularPayment: true)
        try repo.createPlan(monthlyPlan: rub(30000), available: rub(35000), asOf: now, timeZone: "Europe/Moscow",
                            reserves: [rent], scope: .family, payday: end, startingAt: start)
        let first = try #require(try repo.load(asOf: now, scope: .family))
        try repo.save(LedgerRecord(transaction: TransactionSnapshot(amount: rub(700), kind: .expense, date: now,
            authorID: author, payerID: author), title: "Кафе"), in: first, expectedRevision: nil, asOf: now)

        // The same period as another iPhone created it, imported with its own spend and reserve copy.
        let context = repo.container.viewContext
        let household = try repo.object("Household", id: first.snapshot.id)
        let twin = NSEntityDescription.insertNewObject(forEntityName: "BudgetPeriod", into: context)
        let twinID = UUID()
        for (key, value) in ["id": twinID, "month": start, "endsAt": end, "monthlyPlan": rub(30000).minorUnits,
                             "openingFunds": rub(35000).minorUnits, "currency": "RUB"] as [String: Any] { twin.setValue(value, forKey: key) }
        twin.setValue(household, forKey: "household")
        let copy = NSEntityDescription.insertNewObject(forEntityName: "Reserve", into: context)
        for (key, value) in ["id": rent.id, "name": "Аренда", "openingAmount": rub(5000).minorUnits, "isRegularPayment": true] as [String: Any] {
            copy.setValue(value, forKey: key)
        }
        copy.setValue(twin, forKey: "period"); copy.setValue(household, forKey: "household")
        let spend = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: context)
        let other = LedgerRecord(transaction: TransactionSnapshot(amount: rub(300), kind: .expense, date: now,
            authorID: author, payerID: author), title: "Хлеб")
        repo.encode(other, into: spend, updatedAt: now)
        spend.setValue(other.id, forKey: "id"); spend.setValue(twin, forKey: "period"); spend.setValue(household, forKey: "household")
        try context.save()

        #expect(try repo.mergeDuplicatePeriods(scope: .family))
        #expect(try repo.periods(scope: .family).count == 1)
        let merged = try #require(try repo.load(asOf: now, scope: .family))
        #expect(merged.records.count == 2)
        #expect(merged.snapshot.reserves.count == 1)
        #expect(try DailyBudgetCalculator.calculate(merged.snapshot, asOf: now).monthlyRemaining == rub(29000))
        // Running it again on the other device changes nothing.
        #expect(try repo.mergeDuplicatePeriods(scope: .family) == false)
        try repo.close()
    }

    @Test func onlyAnEmptyFamilyIsReplacedSilently() async throws {
        let (repo, path, author) = try await open(); defer { try? FileManager.default.removeItem(at: path) }
        try repo.createPlan(monthlyPlan: rub(0), available: rub(0), asOf: now, timeZone: "Europe/Moscow", scope: .personal)
        try repo.createPlan(monthlyPlan: rub(1000), available: rub(1000), asOf: now, timeZone: "Europe/Moscow", scope: .family)
        #expect(try repo.familyIsEmpty())
        let family = try #require(try repo.load(asOf: now, scope: .family))
        try repo.save(LedgerRecord(transaction: TransactionSnapshot(amount: rub(100), kind: .expense, date: now,
            authorID: author, payerID: author), title: ""), in: family, expectedRevision: nil, asOf: now)
        #expect(try repo.familyIsEmpty() == false)
        try repo.removeOwnFamily()
        #expect(try repo.load(asOf: now, scope: .family) == nil)
        #expect(try repo.load(asOf: now, scope: .personal) != nil)
        try repo.close()
    }
}
