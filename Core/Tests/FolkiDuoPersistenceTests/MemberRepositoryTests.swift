import Foundation
import Testing
import CoreData
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor struct MemberRepositoryTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T09:00:00Z")!
    private func rub(_ n: Int64) -> Money { Money(minorUnits: n * 100) }
    private func path() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("FolkiMembers-\(UUID())") }
    private func budget(_ repo: BudgetRepository, scope: BudgetScope = .personal) throws -> StoredBudget { try #require(try repo.load(asOf: now, scope: scope)) }
    @Test func familyAcceptsFiveMembersAndKeepsThemAfterReopen() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID(), repo = try await BudgetRepository.open(directory: directory, localMemberID: author)
        for scope in BudgetScope.allCases { try repo.createPlan(monthlyPlan: rub(10000), available: rub(10000), asOf: now, scope: scope) }
        for name in ["Третий", "Четвёртый", "Пятый"] { try repo.addFamilyMember(name: name, in: budget(repo, scope: .family), asOf: now) }
        #expect(try budget(repo, scope: .family).members.count == 5)
        #expect(throws: LedgerError.familyFull) { try repo.addFamilyMember(name: "Шестой", in: budget(repo, scope: .family), asOf: now) }
        #expect(throws: LedgerError.accessDenied) { try repo.addFamilyMember(name: "Нет", in: budget(repo), asOf: now) }
        try repo.close()
        let reopened = try await BudgetRepository.open(directory: directory, localMemberID: author)
        #expect(try reopened.load(asOf: now, scope: .family)?.members.count == 5)
        #expect(try reopened.load(asOf: now, scope: .personal)?.members.count == 1)
        try reopened.close()
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
