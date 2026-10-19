import Foundation
import Testing
import CoreData
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor struct PlanningRepositoryTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T09:00:00Z")!
    private func rub(_ n: Int64) -> Money { Money(minorUnits: n * 100) }
    private func path() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("FolkiPlanning-\(UUID())") }
    private func budget(_ repo: BudgetRepository, scope: BudgetScope = .personal) throws -> StoredBudget { try #require(try repo.load(asOf: now, scope: scope)) }
    @Test func reservedBillIsAtomicPaidOnceAndCarriedIntoNextMonth() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID(), repo = try await BudgetRepository.open(directory: directory, localMemberID: author)
        try repo.createPlan(monthlyPlan: rub(10000), available: rub(10000), asOf: now, timeZone: "Europe/Moscow", scope: .personal)
        let original = try budget(repo), due = now.addingTimeInterval(86400 * 20)
        try repo.createObligation(name: "Аренда", amount: rub(3000), due: due, recurrence: .monthly, category: .home, reserveNow: true, in: original, asOf: now)
        let current = try budget(repo)
        #expect(try DailyBudgetCalculator.calculate(current.snapshot, asOf: now).monthlyRemaining == rub(7000))
        #expect(current.records.count == 1)
        let bill = try #require(try repo.obligations(scope: .personal, asOf: now).first)
        try repo.reserveObligation(bill, in: current, asOf: now)
        #expect(try repo.history(scope: .personal).count == 1)
        let later = ISO8601DateFormatter().date(from: "2026-11-02T09:00:00Z")!
        try repo.createPlan(monthlyPlan: rub(10000), available: rub(10000), asOf: later, scope: .personal)
        let november = try #require(try repo.load(asOf: later, scope: .personal))
        #expect(november.snapshot.reserves.first?.openingAmount == rub(3000))
        try repo.payObligation(bill, in: november, asOf: later)
        try repo.payObligation(bill, in: november, asOf: later)
        let paid = try #require(try repo.load(asOf: later, scope: .personal))
        #expect(try DailyBudgetCalculator.calculate(paid.snapshot, asOf: later).monthlyRemaining == rub(7000))
        #expect(paid.records.filter { $0.transaction.kind == .expense }.count == 1)
        let bills = try repo.obligations(scope: .personal, asOf: later)
        #expect(bills.count == 2); #expect(bills.filter(\.isPending).first?.reserved == rub(0))
        let payment = try #require(paid.records.first)
        #expect(throws: BudgetError.invalidTransaction) { try repo.save(payment, in: paid, expectedRevision: payment.revision, asOf: later) }
        try repo.close()
        let reopen = try await BudgetRepository.open(directory: directory, localMemberID: author)
        #expect(try reopen.obligations(scope: .personal, asOf: later).count == 2)
        try reopen.close()
    }
    @Test func insufficientReservationRollsBackAndCancellationReleasesExactlyOnce() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: UUID())
        try repo.createPlan(monthlyPlan: rub(1000), available: rub(1000), asOf: now, scope: .personal)
        let b = try budget(repo)
        #expect(throws: BudgetError.insufficientReserve) { try repo.createObligation(name: "Слишком много", amount: rub(1001), due: now, recurrence: .once, category: .other, reserveNow: true, in: b, asOf: now) }
        #expect(try repo.obligations(scope: .personal, asOf: now).isEmpty)
        try repo.createObligation(name: "Связь", amount: rub(400), due: now, recurrence: .once, category: .other, reserveNow: true, in: b, asOf: now)
        let bill = try #require(try repo.obligations(scope: .personal, asOf: now).first)
        try repo.cancelObligation(bill, in: try budget(repo), asOf: now)
        try repo.cancelObligation(bill, in: try budget(repo), asOf: now)
        #expect(try DailyBudgetCalculator.calculate(budget(repo).snapshot, asOf: now).monthlyRemaining == rub(1000))
        #expect(try repo.history(scope: .personal).count == 2)
        try repo.close()
    }
    @Test func expectedIncomeDoesNotChangeCashUntilReceivedAndRepeatIsIdempotent() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: UUID())
        try repo.createPlan(monthlyPlan: rub(1000), available: rub(1000), asOf: now, scope: .personal)
        let b = try budget(repo)
        try repo.createExpectedIncome(name: "Зарплата", amount: rub(2000), due: now, recurrence: .monthly, in: b, asOf: now)
        #expect(try budget(repo).records.isEmpty)
        #expect(try DailyBudgetCalculator.calculate(budget(repo).snapshot, asOf: now).monthlyRemaining == rub(1000))
        let income = try #require(try repo.expectedIncomes(scope: .personal).first)
        try repo.receiveIncome(income, in: b, asOf: now); try repo.receiveIncome(income, in: b, asOf: now)
        #expect(try DailyBudgetCalculator.calculate(budget(repo).snapshot, asOf: now).monthlyRemaining == rub(3000))
        #expect(try repo.expectedIncomes(scope: .personal).filter(\.isPending).count == 1)
        #expect(try budget(repo).records.count == 1)
        try repo.close()
    }
    @Test func familyAcceptsFiveMembersAndCategoryLimitsAndGoalPlansStayScoped() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID(), repo = try await BudgetRepository.open(directory: directory, localMemberID: author)
        for scope in BudgetScope.allCases { try repo.createPlan(monthlyPlan: rub(10000), available: rub(10000), asOf: now, scope: scope) }
        for name in ["Третий", "Четвёртый", "Пятый"] { try repo.addFamilyMember(name: name, in: budget(repo, scope: .family), asOf: now) }
        #expect(try budget(repo, scope: .family).members.count == 5)
        #expect(throws: LedgerError.familyFull) { try repo.addFamilyMember(name: "Шестой", in: budget(repo, scope: .family), asOf: now) }
        let b = try budget(repo)
        try repo.setCategoryLimit(category: .groceries, amount: rub(3000), expected: nil, in: b, asOf: now)
        let limit = try #require(try repo.categoryLimits(scope: .personal).first)
        #expect(throws: LedgerError.conflict) { try repo.setCategoryLimit(category: .groceries, amount: rub(4000), expected: nil, in: b, asOf: now) }
        #expect(try repo.categoryLimits(scope: .family).isEmpty)
        try repo.createGoal(name: "Подушка", target: rub(50000), deadline: now.addingTimeInterval(86400 * 90), monthlyContribution: rub(2000), purpose: .emergency, in: b, asOf: now)
        let goal = try #require(try repo.goals(scope: .personal, asOf: now).first)
        #expect(goal.monthlyContribution == rub(2000)); #expect(goal.purpose == .emergency)
        try repo.updateGoal(goal, deadline: nil, monthlyContribution: rub(2500), purpose: .irregular, in: b, asOf: now)
        #expect(throws: LedgerError.conflict) { try repo.updateGoal(goal, deadline: nil, monthlyContribution: nil, purpose: .goal, in: b, asOf: now) }
        let forged = StoredBudget(snapshot: b.snapshot, periodID: b.periodID, members: b.members, records: b.records, scope: .family)
        #expect(throws: LedgerError.accessDenied) { try repo.createExpectedIncome(name: "Нет", amount: rub(100), due: now, recurrence: .once, in: forged, asOf: now) }
        try repo.close()
        let reopened = try await BudgetRepository.open(directory: directory, localMemberID: author)
        #expect(try reopened.categoryLimits(scope: .personal).first?.amount == limit.amount)
        #expect(try reopened.goals(scope: .personal, asOf: now).first?.monthlyContribution == rub(2500))
        #expect(try reopened.load(asOf: now, scope: .family)?.members.count == 5)
        try reopened.close()
    }
    @Test func incompletePaymentImportCannotShowAConsistentBudget() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: UUID())
        try repo.createPlan(monthlyPlan: rub(1000), available: rub(1000), asOf: now, scope: .personal)
        try repo.createObligation(name: "Платёж", amount: rub(100), due: now, recurrence: .once, category: .home, reserveNow: true, in: budget(repo), asOf: now)
        let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        let allocation = try #require(try repo.container.viewContext.fetch(request).first)
        repo.container.viewContext.delete(allocation)
        try repo.container.viewContext.save()
        #expect(throws: LedgerError.corruptStore) { try repo.load(asOf: now, scope: .personal) }
        try repo.close()
    }

    @Test func removingMemberFreesSeatWithoutReassigningHistoricalPayerID() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID(), repo = try await BudgetRepository.open(directory: directory, localMemberID: author)
        try repo.createPlan(monthlyPlan: rub(1000), available: rub(1000), asOf: now)
        for name in ["Третий", "Четвёртый", "Пятый"] { try repo.addFamilyMember(name: name, in: budget(repo, scope: .family), asOf: now) }
        let b = try budget(repo, scope: .family), member = try #require(b.members.first { $0.name == "Пятый" })
        let record = LedgerRecord(transaction: TransactionSnapshot(amount: rub(50), kind: .expense, date: now, authorID: author, payerID: member.id), title: "Покупка")
        try repo.save(record, in: b, expectedRevision: nil, asOf: now)
        try await repo.removeFamilyMember(member, in: b, asOf: now)
        try repo.addFamilyMember(name: "Новый", in: budget(repo, scope: .family), asOf: now)
        let updated = try budget(repo, scope: .family)
        #expect(updated.members.filter(\.isActive).count == 5)
        #expect(updated.members.first { $0.id == member.id }?.isActive == false)
        #expect(updated.members.first { $0.name == "Новый" }?.id != member.id)
        #expect(updated.records.first?.transaction.payerID == member.id)
        #expect(throws: LedgerError.invalidMember) { try repo.save(LedgerRecord(transaction: TransactionSnapshot(amount: rub(1), kind: .expense, date: now, authorID: author, payerID: member.id), title: "Нет"), in: b, expectedRevision: nil, asOf: now) }
        try repo.close()
    }

}
