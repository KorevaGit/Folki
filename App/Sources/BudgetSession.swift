import Foundation
import Observation
import FolkiDuoCore
import FolkiDuoPersistence

struct BudgetDayOverview {
    let result: DailyBudgetSnapshot?
    let records: [LedgerRecord]
    let errorMessage: String?
}

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
    var calendar: Calendar {
        var value = household?.period.calendar ?? Calendar.current
        value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        return value
    }
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

    /// Browsing a day must never move the live session or the date used by entry forms.
    func overview(on day: Date) -> BudgetDayOverview {
        let calendar = household?.period.calendar ?? Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else {
            return BudgetDayOverview(result: nil, records: [], errorMessage: "Не удалось определить дату.")
        }
        let cutoff = min(referenceDate, nextDay.addingTimeInterval(-0.001))
        let selectedRecords: ([LedgerRecord]) -> [LedgerRecord] = { records in
            records.filter { !$0.transaction.isDeleted && $0.transaction.date >= start && $0.transaction.date <= cutoff }
        }
        if calendar.isDate(day, inSameDayAs: referenceDate) {
            return BudgetDayOverview(result: result, records: selectedRecords(allRecords), errorMessage: errorMessage)
        }
        do {
            let snapshot: HouseholdSnapshot?
            let records: [LedgerRecord]
            if let repository {
                let budget = try repository.load(asOf: cutoff, scope: scope)
                snapshot = budget?.snapshot
                records = budget?.records ?? []
            } else {
                snapshot = household?.period.contains(cutoff) == true ? household : nil
                records = allRecords
            }
            let result = try snapshot.map { try DailyBudgetCalculator.calculate($0, asOf: cutoff) }
            return BudgetDayOverview(result: result, records: selectedRecords(records), errorMessage: nil)
        } catch {
            return BudgetDayOverview(result: nil, records: [], errorMessage: "Не удалось прочитать выбранный день. Попробуйте ещё раз.")
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

    func updateSpendingLimit(_ amount: Money, expected budget: StoredBudget) throws {
        if let repository {
            try repository.updateSpendingLimit(amount, in: budget, asOf: referenceDate)
        } else {
            guard isDemo, let current = household, amount.currency == .rub, amount.minorUnits > 0,
                  current.id == budget.snapshot.id, current.monthlyFreePlan == budget.snapshot.monthlyFreePlan else { throw LedgerError.conflict }
            household = HouseholdSnapshot(id: current.id, period: current.period, monthlyFreePlan: amount,
                openingFunds: current.openingFunds, reserves: current.reserves, transactions: current.transactions)
        }
        refresh()
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

@MainActor enum MoneyText {
    static func string(_ money: Money) -> String {
        string(money, quote: CurrencyDisplay.shared.activeQuote)
    }
    static func string(_ money: Money, quote: CurrencyQuote?) -> String {
        let displayed: Money
        if let quote {
            guard let converted = try? quote.fromRubles(money) else { return "—" }
            displayed = converted
        } else { displayed = money }
        return formatted(displayed)
    }
    private static func formatted(_ money: Money) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU"); formatter.numberStyle = .currency
        formatter.currencyCode = money.currency.code
        formatter.minusSign = "−"
        formatter.minimumFractionDigits = 0; formatter.maximumFractionDigits = money.currency.fractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: money.decimalValue)) ?? "—"
    }
    static func input(_ money: Money) -> String {
        let converted = CurrencyDisplay.shared.activeQuote.flatMap { try? $0.fromRubles(money) } ?? money
        return NSDecimalNumber(decimal: converted.decimalValue).stringValue
    }
    static func parse(_ text: String, preserving original: Money? = nil) throws -> Money {
        let display = CurrencyDisplay.shared
        let entered = try Money(parsing: text, currency: display.currency)
        return try display.activeQuote?.toRubles(entered, preserving: original) ?? entered
    }
}
