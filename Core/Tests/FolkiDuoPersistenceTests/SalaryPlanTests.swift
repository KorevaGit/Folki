import Foundation
import CoreData
import Testing
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor struct SalaryPlanTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
    private func rub(_ value: Int64) -> Money { Money(minorUnits: value * 100) }
    private func makeRecord(_ budget: StoredBudget, amount: Int64, funding: BudgetFunding = .flexible, at date: Date) -> LedgerRecord {
        let author = budget.members[0].id
        return LedgerRecord(transaction: TransactionSnapshot(amount: rub(amount), kind: .expense, funding: funding,
            date: date, authorID: author, payerID: author), title: "Покупка")
    }
    private func create(_ repo: BudgetRepository) throws {
        try repo.createPlan(monthlyPlan: rub(10000), available: rub(10000), asOf: now, timeZone: "Europe/Moscow",
            scope: .personal, payday: now.addingTimeInterval(10 * 86400))
    }
    @Test func salaryPlanPreservesSpendingAndPaymentsSurviveReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let member = UUID(), repo = try await BudgetRepository.open(directory: directory, localMemberID: member)
        try create(repo)
        var budget = try #require(try repo.load(asOf: now, scope: .personal))
        let purchase = makeRecord(budget, amount: 1000, at: now)
        try repo.save(purchase, in: budget, expectedRevision: nil, asOf: now)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        let rent = ProtectedReserve(name: "Аренда", openingAmount: rub(3000), isRegularPayment: true)
        let savings = ProtectedReserve(name: "Копилка", openingAmount: rub(2000))
        try repo.updateSalaryPlan(available: rub(10000), reserves: [rent, savings], in: budget, asOf: now)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        #expect(budget.records.map(\.id) == [purchase.id])
        #expect(budget.snapshot.monthlyFreePlan == rub(5000))
        let before = try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now)
        let payment = makeRecord(budget, amount: 3000, funding: .reserve(rent.id), at: now)
        try repo.save(payment, in: budget, expectedRevision: nil, asOf: now)
        try repo.close()
        let reopened = try await BudgetRepository.open(directory: directory, localMemberID: member)
        budget = try #require(try reopened.load(asOf: now, scope: .personal))
        let result = try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now)
        #expect(budget.snapshot.reserves.first { $0.id == rent.id }?.isRegularPayment == true)
        #expect(result.monthlyRemaining == rub(4000))
        #expect(result.periodRemaining == rub(4000))
        #expect(result.todayRemaining == before.todayRemaining)
        #expect(result.periodPlan == rub(8000))
        try reopened.close()
    }
    @Test func stalePlanCannotOverwriteNewOperationOrHidePaidReserve() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: UUID())
        try create(repo)
        let initial = try #require(try repo.load(asOf: now, scope: .personal))
        let rent = ProtectedReserve(name: "Аренда", openingAmount: rub(3000), isRegularPayment: true)
        try repo.updateSalaryPlan(available: rub(10000), reserves: [rent], in: initial, asOf: now)
        var current = try #require(try repo.load(asOf: now, scope: .personal))
        try repo.save(makeRecord(current, amount: 1000, funding: .reserve(rent.id), at: now), in: current, expectedRevision: nil, asOf: now)
        #expect(throws: LedgerError.conflict) { try repo.updateSalaryPlan(available: rub(10000), reserves: [rent], in: current, asOf: now) }
        current = try #require(try repo.load(asOf: now, scope: .personal))
        #expect(throws: BudgetError.insufficientReserve) { try repo.updateSalaryPlan(available: rub(10000), reserves: [], in: current, asOf: now) }
        let unchanged = try #require(try repo.load(asOf: now, scope: .personal))
        #expect(unchanged.snapshot.reserves == current.snapshot.reserves)
        #expect(unchanged.records.count == 1)
        try repo.close()
    }
    @Test func earlySalaryHasNoOverlapAndKeepsTheMorningPurchase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: UUID())
        try create(repo)
        let morning = now.addingTimeInterval(86400), salary = morning.addingTimeInterval(3600)
        let old = try #require(try repo.load(asOf: morning, scope: .personal))
        let purchase = makeRecord(old, amount: 1000, at: morning)
        try repo.save(purchase, in: old, expectedRevision: nil, asOf: morning)
        try repo.createPlan(monthlyPlan: rub(20000), available: rub(20000), asOf: salary, scope: .personal,
            payday: salary.addingTimeInterval(30 * 86400), closeCurrent: true)
        let previous = try #require(try repo.load(asOf: morning, scope: .personal))
        let current = try #require(try repo.load(asOf: salary, scope: .personal))
        #expect(previous.periodID == old.periodID)
        #expect(previous.snapshot.period.endExclusive == current.snapshot.period.start)
        #expect(current.snapshot.period.start == salary)
        #expect(previous.records.first?.id == purchase.id)
        #expect(current.records.isEmpty)
        #expect(try DailyBudgetCalculator.calculate(previous.snapshot, asOf: morning).remainingDays == 1)
        #expect(try repo.periods(scope: .personal).count == 2)
        #expect(try repo.history(scope: .personal).count == 1)
        #expect(try repo.load(asOf: now.addingTimeInterval(-86400), scope: .personal) == nil)
        try repo.close()
    }
    @Test func salaryPlanDoesNotReplaceGoalReserves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: UUID())
        try create(repo)
        var budget = try #require(try repo.load(asOf: now, scope: .personal))
        try repo.createGoal(name: "Отпуск", target: rub(10000), in: budget, asOf: now)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        let goal = try #require(try repo.goals(scope: .personal, asOf: now).first)
        try repo.transferToGoal(goal.id, amount: rub(1000), withdrawal: false, in: budget, asOf: now)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        let rent = ProtectedReserve(name: "Аренда", openingAmount: rub(2000), isRegularPayment: true)
        try repo.updateSalaryPlan(available: rub(10000), reserves: [rent], in: budget, asOf: now)
        budget = try #require(try repo.load(asOf: now, scope: .personal))
        let result = try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now)
        #expect(result.reserveBalances[goal.id] == rub(1000))
        #expect(result.monthlyRemaining == rub(7000))
        #expect(result.periodRemaining == rub(9000))
        #expect(try repo.goals(scope: .personal, asOf: now).first?.balance == rub(1000))
        try repo.close()
    }

    @Test(arguments: [1, 2]) func earlierStoresMigrateWithoutLosingBudget(version: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = try #require(try BudgetRepository.managedObjectModel().copy() as? NSManagedObjectModel)
        let reserveEntity = try #require(model.entitiesByName["Reserve"])
        reserveEntity.properties.removeAll { $0.name == "isRegularPayment" }
        if version == 1 { model.entitiesByName["BudgetPeriod"]?.properties.removeAll { $0.name == "endsAt" } }
        model.versionIdentifiers = [AnyHashable(String(version))]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(type: .sqlite, at: directory.appendingPathComponent("private.sqlite"))
        let context = NSManagedObjectContext(.mainQueue); context.persistentStoreCoordinator = coordinator
        let root = NSEntityDescription.insertNewObject(forEntityName: "Household", into: context)
        let householdID = UUID(), memberID = UUID()
        root.setValue(householdID, forKey: "id"); root.setValue("personal", forKey: "scope")
        root.setValue("Europe/Moscow", forKey: "timeZone"); root.setValue(now, forKey: "createdAt")
        root.setValue("Личный", forKey: "name")
        let member = NSEntityDescription.insertNewObject(forEntityName: "Member", into: context)
        member.setValue(memberID, forKey: "id"); member.setValue("Я", forKey: "name"); member.setValue(root, forKey: "household")
        let period = NSEntityDescription.insertNewObject(forEntityName: "BudgetPeriod", into: context)
        let bounds = try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow")
        period.setValue(UUID(), forKey: "id"); period.setValue(bounds.start, forKey: "month")
        if version == 2 { period.setValue(bounds.endExclusive, forKey: "endsAt") }
        period.setValue(Int64(800000), forKey: "monthlyPlan"); period.setValue(Int64(1000000), forKey: "openingFunds")
        period.setValue("RUB", forKey: "currency"); period.setValue(root, forKey: "household")
        let reserve = NSEntityDescription.insertNewObject(forEntityName: "Reserve", into: context)
        reserve.setValue(UUID(), forKey: "id"); reserve.setValue("Копилка", forKey: "name")
        reserve.setValue(Int64(200000), forKey: "openingAmount")
        reserve.setValue(period, forKey: "period"); reserve.setValue(root, forKey: "household")
        try context.save(); context.reset(); try coordinator.remove(store)
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: memberID)
        let budget = try #require(try repo.load(asOf: now, scope: .personal))
        #expect(budget.snapshot.id == householdID)
        #expect(budget.snapshot.reserves.first?.isRegularPayment == false)
        #expect(try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now).monthlyRemaining == rub(8000))
        try repo.close()
    }
}
