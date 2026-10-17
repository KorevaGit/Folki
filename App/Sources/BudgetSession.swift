import Foundation
import Observation
import FolkiDuoCore
import FolkiDuoPersistence

@MainActor @Observable
final class BudgetSession {
    let scope: BudgetScope
    private(set) var goals: [SavingsGoalSnapshot] = []
    private(set) var household: HouseholdSnapshot?
    private(set) var result: DailyBudgetSnapshot?
    private(set) var allRecords: [LedgerRecord]
    private(set) var historyRecords: [LedgerRecord] = []
    private(set) var errorMessage: String?
    private(set) var members: [Member]
    private(set) var authorID: UUID?
    private var periodID = UUID()
    let repository: BudgetRepository?
    let demoDate: Date?
    var records: [LedgerRecord] { allRecords.filter { !$0.transaction.isDeleted } }
    var deletedRecords: [LedgerRecord] { allRecords.filter { $0.transaction.isDeleted } }
    var referenceDate: Date { demoDate ?? .now }
    var isDemo: Bool { demoDate != nil }
    var storedBudget: StoredBudget? {
        guard let household else { return nil }
        return StoredBudget(snapshot: household, periodID: periodID, members: members, records: allRecords, scope: scope)
    }

    init(scope: BudgetScope = .family, repository: BudgetRepository? = nil, household: HouseholdSnapshot? = nil, records: [LedgerRecord] = [],
         members: [Member] = [], demoDate: Date? = nil) {
        self.scope = scope
        self.repository = repository; self.household = household
        allRecords = records; self.members = members; self.demoDate = demoDate
        authorID = members.first?.id
        historyRecords = records
        refresh()
    }

    func refresh() {
        if let repository {
            do {
                let stored = try repository.load(asOf: referenceDate, scope: scope)
                household = stored?.snapshot
                allRecords = stored?.records ?? []
                historyRecords = try repository.history(scope: scope)
                goals = try repository.goals(scope: scope, asOf: referenceDate)
                members = stored?.members ?? []
                if let stored {
                    periodID = stored.periodID
                    authorID = try repository.authorID(in: stored)
                } else { authorID = nil }
            } catch {
                result = nil; errorMessage = "Не удалось прочитать бюджет или подтвердить доступ. Локальные данные сохранены."
                return
            }
        }
        guard let household else { result = nil; errorMessage = nil; return }
        do {
            result = try DailyBudgetCalculator.calculate(household, asOf: referenceDate)
            errorMessage = nil
        } catch BudgetError.dateOutsidePeriod {
            result = nil; errorMessage = "Период закончился. Создайте новый план месяца. История сохранится."
        } catch {
            result = nil; errorMessage = "Не удалось рассчитать бюджет. Проверьте суммы и резервы."
        }
    }

    func createPlan(monthlyPlan: Money, available: Money, reserves: [ProtectedReserve] = []) throws {
        if let repository {
            try repository.createPlan(monthlyPlan: monthlyPlan, available: available, asOf: referenceDate, reserves: reserves, scope: scope)
            refresh()
            return
        }
        guard isDemo else { throw LedgerError.unavailable }
        let period = try BudgetPeriod(monthContaining: referenceDate, timeZoneIdentifier: TimeZone.current.identifier)
        household = HouseholdSnapshot(period: period, monthlyFreePlan: monthlyPlan, openingFunds: available, reserves: reserves)
        allRecords = []; refresh()
    }

    func draft(amount: Money, title: String, payerID: UUID, date: Date, kind: TransactionKind,
               category: ExpenseCategory, funding: BudgetFunding, editing: LedgerRecord? = nil,
               deleted: Bool = false, newRecordID: UUID = UUID()) throws -> LedgerRecord {
        guard let authorID else { throw LedgerError.invalidMember }
        return LedgerRecord(transaction: TransactionSnapshot(id: editing?.id ?? newRecordID, amount: amount, kind: kind,
            funding: funding, date: date, authorID: editing?.transaction.authorID ?? authorID, payerID: payerID,
            isDeleted: deleted), title: title.trimmingCharacters(in: .whitespacesAndNewlines), category: category)
    }
    func budget(editing record: LedgerRecord?) throws -> StoredBudget {
        if let record, let repository, let stored = try repository.load(asOf: record.transaction.date, scope: scope) { return stored }
        guard let budget = storedBudget else { throw LedgerError.unavailable }
        return budget
    }
    func calculationDate(in budget: StoredBudget) -> Date {
        min(referenceDate, budget.snapshot.period.endExclusive.addingTimeInterval(-0.001))
    }
    func preview(_ record: LedgerRecord, editing: LedgerRecord? = nil) throws -> DailyBudgetSnapshot {
        let budget = try budget(editing: editing)
        let date = calculationDate(in: budget)
        return try DailyBudgetCalculator.calculate(LedgerRules.replacing(record, in: budget, asOf: date).snapshot, asOf: date)
    }
    func save(_ record: LedgerRecord, editing: LedgerRecord? = nil) throws {
        let budget = try budget(editing: editing)
        let date = calculationDate(in: budget)
        if let repository {
            try repository.save(record, in: budget, expectedRevision: editing?.revision, asOf: date)
        } else {
            guard isDemo else { throw LedgerError.unavailable }
            let candidate = try LedgerRules.replacing(record, in: budget, asOf: date)
            household = candidate.snapshot; allRecords = candidate.records; historyRecords = candidate.records
        }
        refresh()
    }
    func setDeleted(_ deleted: Bool, record: LedgerRecord) throws {
        let entry = record.transaction
        let draft = try draft(amount: entry.amount, title: record.title, payerID: entry.payerID, date: entry.date,
            kind: entry.kind, category: record.category, funding: entry.funding, editing: record, deleted: deleted)
        try save(draft, editing: record)
    }
    func createGoal(name: String, target: Money) throws {
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        try repository.createGoal(name: name, target: target, in: budget, asOf: referenceDate)
        refresh()
    }
    func transfer(goal: SavingsGoalSnapshot, amount: Money, withdrawal: Bool, operationID: UUID) throws {
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        try repository.transferToGoal(goal.id, amount: amount, withdrawal: withdrawal, in: budget, asOf: referenceDate, operationID: operationID)
        refresh()
    }
    func isEditable(_ record: LedgerRecord) -> Bool {
        [.expense, .refund, .income].contains(record.transaction.kind)
    }
    func payerName(for record: LedgerRecord) -> String {
        memberName(record.transaction.payerID)
    }
    func memberName(_ id: UUID) -> String {
        guard let member = members.first(where: { $0.id == id }) else { return "Участник" }
        guard !isDemo else { return member.name }
        if id == authorID { return "Я" }
        return member.name == "Я" ? "Партнёр" : member.name
    }
}

enum MoneyText {
    static func string(_ money: Money) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU"); formatter.numberStyle = .currency
        formatter.currencyCode = money.currency.code
        formatter.minimumFractionDigits = 0; formatter.maximumFractionDigits = money.currency.fractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: money.decimalValue)) ?? "—"
    }
    static func input(_ money: Money) -> String { NSDecimalNumber(decimal: money.decimalValue).stringValue }
}
