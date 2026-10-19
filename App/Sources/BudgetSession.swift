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
    private(set) var catalog = CategoryCatalog()
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

    /// Past days are read from storage; the calendar asks for the same days many times per frame.
    @ObservationIgnored private var overviewCache: [Date: BudgetDayOverview] = [:]

    func refresh() {
        overviewCache = [:]
        if let repository {
            do {
                let stored = try repository.load(asOf: referenceDate, scope: scope)
                household = stored?.snapshot
                allRecords = stored?.records ?? []
                historyRecords = try repository.history(scope: scope)
                goals = try repository.goals(scope: scope, asOf: referenceDate)
                catalog = try repository.catalog(scope: scope)
                members = stored?.members ?? []
                if let stored {
                    periodID = stored.periodID
                    authorID = try repository.authorID(in: stored)
                } else { authorID = nil }
            } catch {
                result = nil; errorMessage = "Не получилось прочитать бюджет или подтвердить доступ. Локальные данные сохранены."
                return
            }
        }
        guard let household else { result = nil; errorMessage = nil; return }
        do {
            result = try DailyBudgetCalculator.calculate(household, asOf: referenceDate)
            errorMessage = nil
        } catch BudgetError.dateOutsidePeriod {
            result = nil; errorMessage = "Период закончился. Создай новый план месяца. История сохранится."
        } catch {
            result = nil; errorMessage = "Не получилось рассчитать бюджет. Проверь суммы и резервы."
        }
    }

    /// Browsing a day must never move the live session or the date used by entry forms.
    func overview(on day: Date) -> BudgetDayOverview {
        let calendar = household?.period.calendar ?? Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else {
            return BudgetDayOverview(result: nil, records: [], errorMessage: "Не получилось определить дату.")
        }
        let cutoff = min(referenceDate, nextDay.addingTimeInterval(-0.001))
        let selectedRecords: ([LedgerRecord]) -> [LedgerRecord] = { records in
            records.filter { !$0.transaction.isDeleted && $0.transaction.date >= start && $0.transaction.date <= cutoff }
        }
        if calendar.isDate(day, inSameDayAs: referenceDate) {
            return BudgetDayOverview(result: result, records: selectedRecords(allRecords), errorMessage: errorMessage)
        }
        if let cached = overviewCache[start] { return cached }
        let overview = pastOverview(start: start, cutoff: cutoff, selectedRecords: selectedRecords)
        if overview.errorMessage == nil { overviewCache[start] = overview }
        return overview
    }

    private func pastOverview(start: Date, cutoff: Date, selectedRecords: ([LedgerRecord]) -> [LedgerRecord]) -> BudgetDayOverview {
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
            return BudgetDayOverview(result: nil, records: [], errorMessage: "Не получилось прочитать выбранный день. Попробуй ещё раз.")
        }
    }

    func createPlan(monthlyPlan: Money, available: Money, reserves: [ProtectedReserve] = []) throws {
        overviewCache = [:]
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
               categoryID: UUID, funding: BudgetFunding, editing: LedgerRecord? = nil,
               deleted: Bool = false, newRecordID: UUID = UUID()) throws -> LedgerRecord {
        guard let authorID else { throw LedgerError.invalidMember }
        return LedgerRecord(transaction: TransactionSnapshot(id: editing?.id ?? newRecordID, amount: amount, kind: kind,
            funding: funding, date: date, authorID: editing?.transaction.authorID ?? authorID, payerID: payerID,
            isDeleted: deleted), title: title.trimmingCharacters(in: .whitespacesAndNewlines), categoryID: categoryID)
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
        overviewCache = [:]
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
        overviewCache = [:]
        let entry = record.transaction
        let draft = try draft(amount: entry.amount, title: record.title, payerID: entry.payerID, date: entry.date,
            kind: entry.kind, categoryID: record.categoryID, funding: entry.funding, editing: record, deleted: deleted)
        try save(draft, editing: record)
    }
    func createGoal(name: String, target: Money) throws {
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        try repository.createGoal(name: name, target: target, in: budget, asOf: referenceDate)
        refresh()
    }
    func transfer(goal: SavingsGoalSnapshot, amount: Money, withdrawal: Bool, operationID: UUID) throws {
        overviewCache = [:]
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        try repository.transferToGoal(goal.id, amount: amount, withdrawal: withdrawal, in: budget, asOf: referenceDate, operationID: operationID)
        refresh()
    }
    /// Today's and the month's numbers after a transfer that is not a ledger form: a contribution side or a savings move.
    func previewTransfer(_ amount: Money, kind: TransactionKind, funding: BudgetFunding = .flexible) -> DailyBudgetSnapshot? {
        guard let authorID else { return nil }
        let record = LedgerRecord(transaction: TransactionSnapshot(amount: amount, kind: kind, funding: funding,
            date: referenceDate, authorID: authorID, payerID: authorID), title: "", linkID: kind.isContribution ? UUID() : nil)
        return try? preview(record)
    }
    /// Called on the personal session: moves money from it into the family budget.
    func contribute(_ amount: Money, to family: BudgetSession, linkID: UUID) throws {
        overviewCache = [:]; family.overviewCache = [:]
        guard scope == .personal, family.scope == .family,
              let personalBudget = storedBudget, let familyBudget = family.storedBudget else { throw LedgerError.unavailable }
        if let repository {
            try repository.contribute(amount, from: personalBudget, to: familyBudget, asOf: referenceDate, linkID: linkID)
        } else {
            guard isDemo, let authorID, let familyAuthor = family.authorID else { throw LedgerError.unavailable }
            let out = LedgerRecord(transaction: TransactionSnapshot(amount: amount, kind: .contributionOut, date: referenceDate,
                authorID: authorID, payerID: authorID), title: "В семейный бюджет", linkID: linkID)
            let into = LedgerRecord(transaction: TransactionSnapshot(amount: amount, kind: .contributionIn, date: referenceDate,
                authorID: familyAuthor, payerID: familyAuthor), title: "Взнос в семейный бюджет", linkID: linkID)
            let personalNext = try LedgerRules.replacing(out, in: personalBudget, asOf: referenceDate)
            let familyNext = try LedgerRules.replacing(into, in: familyBudget, asOf: referenceDate)
            apply(personalNext); family.apply(familyNext)
        }
        refresh(); family.refresh()
    }
    func cancelContribution(_ record: LedgerRecord) throws {
        overviewCache = [:]
        guard let linkID = record.linkID, let repository else { throw LedgerError.unavailable }
        try repository.cancelContribution(linkID: linkID, asOf: referenceDate)
        refresh()
    }
    private func apply(_ budget: StoredBudget) {
        household = budget.snapshot; allRecords = budget.records; historyRecords = budget.records
    }
    func addMember(name: String) throws {
        guard let repository, let budget = storedBudget else { throw LedgerError.unavailable }
        try repository.addFamilyMember(name: name, in: budget, asOf: referenceDate); refresh()
    }
    func renameMember(_ member: Member, name: String) throws {
        guard let repository, let budget = storedBudget else { throw LedgerError.unavailable }
        try repository.renameMember(member, name: name, in: budget, asOf: referenceDate); refresh()
    }
    /// The categories used most often in this budget, padded with everyday defaults.
    func frequentCategories(limit: Int = 3) -> [SpendingCategory] {
        let selectable = catalog.selectable
        var counts: [UUID: Int] = [:]
        for record in historyRecords where record.transaction.kind == .expense && !record.transaction.isDeleted {
            counts[record.categoryID, default: 0] += 1
        }
        let used = selectable.filter { counts[$0.id] != nil && $0.id != BuiltInCategory.other.id }
            .sorted { counts[$0.id]! == counts[$1.id]! ? $0.name < $1.name : counts[$0.id]! > counts[$1.id]! }
        let defaults = [BuiltInCategory.groceries, .cafes, .transport].map(\.category)
        var result: [SpendingCategory] = []
        for category in used + defaults where !result.contains(category) && result.count < limit { result.append(category) }
        return result
    }
    /// Nil for contributions and savings transfers, which have no category.
    func category(for record: LedgerRecord) -> SpendingCategory? {
        record.hasCategory ? catalog.category(for: record.categoryID) : nil
    }
    func createCategory(name: String, symbol: String, color: CategoryColor, isEssential: Bool) throws {
        guard let repository, let budget = storedBudget else { throw LedgerError.unavailable }
        try repository.createCategory(name: name, symbol: symbol, color: color, isEssential: isEssential, in: budget, asOf: referenceDate)
        refresh()
    }
    func updateCategory(_ category: SpendingCategory, name: String, symbol: String, color: CategoryColor, isEssential: Bool) throws {
        guard let repository, let budget = storedBudget else { throw LedgerError.unavailable }
        try repository.updateCategory(category, name: name, symbol: symbol, color: color, isEssential: isEssential, in: budget, asOf: referenceDate)
        refresh()
    }
    func setCategoryArchived(_ category: SpendingCategory, archived: Bool) throws {
        guard let repository, let budget = storedBudget else { throw LedgerError.unavailable }
        try repository.setCategoryArchived(category, archived: archived, in: budget, asOf: referenceDate)
        refresh()
    }
    func isEditable(_ record: LedgerRecord) -> Bool {
        [.expense, .refund, .income].contains(record.transaction.kind)
    }
    /// Only the contributor holds both sides, so only they can cancel a contribution.
    func canCancelContribution(_ record: LedgerRecord) -> Bool {
        record.linkID != nil && !isDemo && !record.transaction.isDeleted && record.transaction.authorID == authorID
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
    /// Budgets are kept in rubles; choosing the budget currency comes with localization.
    static let symbol = "₽"
    /// Exact record amount: always show both fractional digits.
    static func string(_ money: Money) -> String {
        format(money, fractionDigits: money.currency.fractionDigits)
    }
    /// Whole units for remainders, forecasts and analytics. Round the amount first (down for what is left).
    static func whole(_ money: Money) -> String {
        format(money.roundedDownToWholeUnits, fractionDigits: 0)
    }
    private static func format(_ money: Money, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU"); formatter.numberStyle = .currency
        formatter.currencyCode = money.currency.code
        formatter.minusSign = "−"
        formatter.minimumFractionDigits = fractionDigits; formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: money.decimalValue)) ?? "—"
    }
    static func input(_ money: Money) -> String {
        NSDecimalNumber(decimal: money.decimalValue).stringValue
    }
    static func parse(_ text: String) throws -> Money {
        try Money(parsing: text)
    }
}
