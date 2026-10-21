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
    private(set) var catalog = CategoryCatalog()
    private(set) var household: HouseholdSnapshot?
    private(set) var periods: [BudgetPeriod] = []
    private(set) var result: DailyBudgetSnapshot?
    private(set) var allRecords: [LedgerRecord]
    private(set) var historyRecords: [LedgerRecord] = []
    private(set) var errorMessage: String?
    private(set) var members: [Member]
    private(set) var authorID: UUID?
    /// Recurring payments of this budget, nearest first.
    private(set) var envelopes: [RecurringEnvelope] = []
    private var periodID = UUID()
    let repository: BudgetRepository?
    let demoDate: Date?
    var fullFinanceEnabled = false {
        didSet { UserDefaults.standard.set(fullFinanceEnabled, forKey: "FolkiFullFinances.\(scope.rawValue)") }
    }
    var envelopeOfferDismissed = false {
        didSet { UserDefaults.standard.set(envelopeOfferDismissed, forKey: "FolkiEnvelopeOfferDismissed.\(scope.rawValue)") }
    }
    /// How a finished period is extended. Stored with the budget, so a family period ends the same way for everyone.
    private(set) var periodRule: PeriodRule = .monthEnd
    var hasFunding: Bool {
        (household?.openingFunds.minorUnits ?? 0) > 0 || records.contains {
            [.income, .contributionIn].contains($0.transaction.kind)
        }
    }
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
        fullFinanceEnabled = UserDefaults.standard.bool(forKey: "FolkiFullFinances.\(scope.rawValue)")
        envelopeOfferDismissed = UserDefaults.standard.bool(forKey: "FolkiEnvelopeOfferDismissed.\(scope.rawValue)")
        allRecords = records; self.members = members; self.demoDate = demoDate
        authorID = members.first?.id
        historyRecords = records
        periodRule = household.map { PeriodRule.inferred(from: $0.period) } ?? .monthEnd
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
                periods = try repository.periods(scope: scope)
                allRecords = stored?.records ?? []
                historyRecords = try repository.history(scope: scope)
                catalog = try repository.catalog(scope: scope)
                envelopes = try repository.envelopes(scope: scope)
                periodRule = try repository.periodRule(scope: scope) ?? stored.map { PeriodRule.inferred(from: $0.snapshot.period) } ?? .monthEnd
                members = stored?.members ?? []
                if let stored {
                    periodID = stored.periodID
                    authorID = try repository.authorID(in: stored)
                } else { authorID = nil }
            } catch {
                result = nil; errorMessage = String(localized: "Не получилось прочитать бюджет или подтвердить доступ. Локальные данные сохранены.")
                return
            }
        }
        if repository == nil { periods = household.map { [$0.period] } ?? [] }
        guard let household else { result = nil; errorMessage = nil; return }
        if referenceDate >= household.period.endExclusive {
            do { try ensureDailyPeriod() }
            catch { result = nil; errorMessage = String(localized: "Не получилось открыть новый период. Попробуй ещё раз.") }
            return
        }
        do {
            result = try DailyBudgetCalculator.calculate(household, asOf: referenceDate)
            errorMessage = nil
        } catch BudgetError.dateOutsidePeriod {
            result = nil; errorMessage = String(localized: "Пришла зарплата? Введи сумму и дату следующей. История сохранится.")
        } catch {
            result = nil; errorMessage = String(localized: "Не получилось рассчитать бюджет. Проверь суммы и резервы.")
        }
    }

    /// Browsing a day must never move the live session or the date used by entry forms.
    func overview(on day: Date) -> BudgetDayOverview {
        let calendar = household?.period.calendar ?? Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else {
            return BudgetDayOverview(result: nil, records: [], errorMessage: String(localized: "Не получилось определить дату."))
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
                snapshot = budget?.snapshot.period.contains(cutoff) == true ? budget?.snapshot : nil
                records = budget?.records ?? []
            } else {
                snapshot = household?.period.contains(cutoff) == true ? household : nil
                records = allRecords
            }
            let result = try snapshot.map { try DailyBudgetCalculator.calculate($0, asOf: cutoff) }
            return BudgetDayOverview(result: result, records: selectedRecords(records), errorMessage: nil)
        } catch {
            return BudgetDayOverview(result: nil, records: [], errorMessage: String(localized: "Не получилось прочитать выбранный день. Попробуй ещё раз."))
        }
    }

    func createPlan(monthlyPlan: Money, available: Money, reserves: [ProtectedReserve] = [], payday: Date, closeCurrent: Bool = false) throws {
        overviewCache = [:]
        if let repository {
            try repository.createPlan(monthlyPlan: monthlyPlan, available: available, asOf: referenceDate, reserves: reserves, scope: scope,
                                      payday: payday, closeCurrent: closeCurrent)
            refresh()
            return
        }
        guard isDemo else { throw LedgerError.unavailable }
        let period = try BudgetPeriod.untilPayday(from: referenceDate, payday: payday, timeZoneIdentifier: calendar.timeZone.identifier)
        household = HouseholdSnapshot(period: period, monthlyFreePlan: monthlyPlan, openingFunds: available, reserves: reserves)
        allRecords = []; refresh()
    }

    /// Opening an entry never requires a salary plan. Carry actual balances across periods.
    func ensureDailyPeriod() throws {
        if household?.period.contains(referenceDate) == true { return }
        var funds = Money(minorUnits: 0), freePlan = Money(minorUnits: 0), reserves: [ProtectedReserve] = []
        if let household {
            let previous = try DailyBudgetCalculator.calculate(household, asOf: household.period.endExclusive.addingTimeInterval(-0.001))
            funds = previous.totalFunds; freePlan = previous.monthlyRemaining.nonnegative
            reserves = household.reserves.map {
                ProtectedReserve(id: $0.id, name: $0.name, openingAmount: previous.reserveBalances[$0.id] ?? Money(minorUnits: 0),
                                 isRegularPayment: $0.isRegularPayment, dueDate: $0.dueDate, targetAmount: $0.targetAmount)
            }
        }
        // The next period follows the previous one: a week stays a week, a payday stays the same date.
        let anchor = household?.period.endExclusive ?? calendar.startOfDay(for: referenceDate)
        try createPlan(monthlyPlan: freePlan, available: funds,
                       reserves: reserves, payday: periodRule.end(after: anchor, now: referenceDate, calendar: calendar))
    }
    /// Changes how this and later periods end; the current period is recut from its own start.
    func setPeriodRule(_ rule: PeriodRule) throws {
        try ensureDailyPeriod()
        if let repository, let budget = storedBudget { try repository.setPeriodRule(rule, in: budget, asOf: referenceDate) }
        periodRule = rule
        if let budget = storedBudget {
            try setPeriodEnd(rule.end(after: budget.snapshot.period.start, now: referenceDate, calendar: calendar), in: budget)
        }
        refresh()
    }
    private func setPeriodEnd(_ end: Date, in budget: StoredBudget) throws {
        guard budget.snapshot.period.contains(referenceDate), budget.snapshot.period.endExclusive != end else { return }
        if let repository { try repository.updatePeriodEnd(end, in: budget, asOf: referenceDate) }
        else if isDemo {
            let source = budget.snapshot
            household = HouseholdSnapshot(id: source.id,
                period: try BudgetPeriod(start: source.period.start, endExclusive: end, timeZoneIdentifier: calendar.timeZone.identifier),
                monthlyFreePlan: source.monthlyFreePlan, openingFunds: source.openingFunds, reserves: source.reserves,
                transactions: source.transactions)
        }
    }
    func addDailyFunds(_ amount: Money, operationID: UUID = UUID()) throws {
        try ensureDailyPeriod()
        guard let authorID else { throw LedgerError.invalidMember }
        let record = try draft(amount: amount, title: "", payerID: authorID, date: referenceDate,
            kind: .income, categoryID: BuiltInCategory.other.id, funding: .flexible, newRecordID: operationID)
        try save(record, addIncomeToPlan: true)
    }

    func previewFunding(_ amount: Money, fills: [UUID: Money], familyShare: Money) -> DailyBudgetSnapshot? {
        guard let household, let authorID,
              let projected = try? FundingPlan.applying(to: household, incoming: amount, fills: fills,
                familyShare: familyShare, now: referenceDate, author: authorID, operationID: UUID()) else { return nil }
        return try? DailyBudgetCalculator.calculate(projected, asOf: referenceDate)
    }

    func deposit(_ amount: Money, fills: [UUID: Money], familyShare: Money, family: BudgetSession, operationID: UUID) throws {
        try ensureDailyPeriod()
        if familyShare.minorUnits > 0 { try family.ensureDailyPeriod() }
        if let repository, let budget = storedBudget {
            try repository.deposit(amount, fills: fills, familyShare: familyShare, in: budget,
                family: family.storedBudget, asOf: referenceDate, operationID: operationID)
            refresh(); family.refresh()
        } else {
            try addDailyFunds(amount, operationID: operationID)
            if familyShare.minorUnits > 0 { try contribute(familyShare, to: family, linkID: operationID) }
            for envelope in envelopes {
                if let fill = fills[envelope.id] { try fundEnvelope(envelope, amount: fill) }
            }
        }
    }

    var availableForDailySpending: Money { result?.monthlyRemaining.nonnegative ?? Money(minorUnits: 0) }

    var hasUnfundedObligations: Bool {
        envelopes.contains { $0.isMandatory && ((try? $0.shortfall(balance: envelopeBalance($0)).minorUnits) ?? 0) > 0 }
    }

    /// Monthly forecast from the plan; actual funds remain the source for today's allowance.
    var plannedDailySpending: Money? {
        let income = Int64(UserDefaults.standard.integer(forKey: "FolkiPlanIncome"))
        guard income > 0, scope == .personal else { return nil }
        let settings = PlanSettings.load()
        let today = calendar.startOfDay(for: referenceDate)
        var days = calendar.range(of: .day, in: .month, for: today)?.count ?? 30
        if case .monthly(let paydays) = settings.income, let first = paydays.first,
           let start = try? EnvelopeSchedule.firstDue(day: first, onOrAfter: today, calendar: calendar),
           let end = calendar.date(byAdding: .month, value: 1, to: start) {
            days = max(1, calendar.dateComponents([.day], from: start, to: end).day ?? days)
        }
        let reserved = envelopes.reduce(Int64(0)) { $0 + $1.size.minorUnits }
        return Money(minorUnits: max(0, income - reserved) / Int64(days))
    }

    func previewAvailableDistribution(_ fills: [UUID: Money]) -> DailyBudgetSnapshot? {
        guard let household, let authorID else { return nil }
        let moves = fills.filter { $0.value.minorUnits > 0 }.map { id, amount in
            TransactionSnapshot(amount: amount, kind: .reserveAllocation, funding: .reserve(id),
                date: referenceDate, authorID: authorID, payerID: authorID)
        }
        let projected = HouseholdSnapshot(id: household.id, period: household.period,
            monthlyFreePlan: household.monthlyFreePlan, openingFunds: household.openingFunds,
            reserves: household.reserves, transactions: household.transactions + moves)
        return try? DailyBudgetCalculator.calculate(projected, asOf: referenceDate)
    }

    func distributeAvailable(_ fills: [UUID: Money], operationID: UUID) throws {
        try ensureDailyPeriod()
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        try repository.distributeAvailable(fills, in: budget, asOf: referenceDate, operationID: operationID)
        refresh()
    }

    // MARK: Envelopes

    func envelopeBalance(_ envelope: RecurringEnvelope) -> Money {
        result?.reserveBalances[envelope.id] ?? Money(minorUnits: 0)
    }
    func envelopeUrgency(_ envelope: RecurringEnvelope) -> EnvelopeUrgency {
        (try? EnvelopeSchedule.urgency(of: envelope, balance: envelopeBalance(envelope), now: referenceDate, calendar: calendar)) ?? .calm
    }
    func daysUntil(_ envelope: RecurringEnvelope) -> Int {
        EnvelopeSchedule.daysUntil(envelope.nextDue, from: referenceDate, calendar: calendar)
    }
    /// The most urgent short envelope, for the banner on the main screen.
    var mostUrgentEnvelope: RecurringEnvelope? {
        envelopes.filter { envelopeUrgency($0) >= .attention }
            .max { (envelopeUrgency($0), -daysUntil($0)) < (envelopeUrgency($1), -daysUntil($1)) }
    }
    func createEnvelope(name: String, size: Money, nextDue: Date, isMandatory: Bool, categoryID: UUID?,
                        symbol: String? = nil, color: CategoryColor? = nil,
                        id: UUID = UUID(), initialFunding: Money = Money(minorUnits: 0)) throws -> RecurringEnvelope {
        try ensureDailyPeriod()
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        let day = calendar.component(.day, from: nextDue)
        let envelope = try repository.createEnvelope(name: name, size: size, dueDay: day, nextDue: nextDue, isMandatory: isMandatory,
                                                     categoryID: categoryID, symbol: symbol, color: color,
                                                     in: budget, asOf: referenceDate, id: id, initialFunding: initialFunding)
        refresh()
        return envelope
    }
    func recommendedFunding(for candidate: RecurringEnvelope) -> Money {
        guard let result, result.monthlyRemaining.minorUnits > 0 else { return Money(minorUnits: 0) }
        let free = result.monthlyRemaining.nonnegative
        let oneDay = free.minorUnits / Int64(max(1, result.remainingDays))
        let keep = Money(minorUnits: max(result.todayGuide.minorUnits, oneDay), currency: free.currency)
        let all = envelopes + [candidate]
        let balances = Dictionary(uniqueKeysWithValues: envelopes.map { ($0.id, envelopeBalance($0)) })
        return (try? EnvelopeDistributor.distribute(incoming: free, envelopes: all, balances: balances,
            periodEnd: household?.period.endExclusive ?? referenceDate, minimumLiving: keep).fills[candidate.id])
            ?? Money(minorUnits: 0)
    }

    func updateEnvelope(_ envelope: RecurringEnvelope) throws {
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        try repository.updateEnvelope(envelope, in: budget, asOf: referenceDate)
        refresh()
    }
    func fundEnvelope(_ envelope: RecurringEnvelope, amount: Money, operationID: UUID = UUID()) throws {
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        try repository.fundEnvelope(envelope.id, amount: amount, in: budget, asOf: referenceDate, operationID: operationID)
        refresh()
    }
    func payEnvelope(_ envelope: RecurringEnvelope, amount: Money, operationID: UUID = UUID()) throws {
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        try repository.payEnvelope(envelope.id, amount: amount, in: budget, asOf: referenceDate, operationID: operationID)
        refresh()
    }
    func spendFromEnvelope(_ envelope: RecurringEnvelope, amount: Money, operationID: UUID = UUID()) throws {
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        try repository.spendFromEnvelope(envelope.id, amount: amount, in: budget, asOf: referenceDate, operationID: operationID)
        refresh()
    }
    func archiveEnvelope(_ envelope: RecurringEnvelope) throws {
        guard let budget = storedBudget, let repository else { throw LedgerError.unavailable }
        try repository.archiveEnvelope(envelope.id, in: budget, asOf: referenceDate)
        refresh()
    }
    /// Called on the family session: this member's suggested share of a personal top-up.
    var contributionPercent: Int {
        guard scope == .family, let repository, let budget = storedBudget else { return 30 }
        return (try? repository.effectiveContributionPercent(in: budget)) ?? 30
    }
    /// Called on the family session: the family default and this member's own percent, if set.
    var contributionPercents: (family: Int, mine: Int?) {
        guard scope == .family, let repository, let budget = storedBudget else { return (30, nil) }
        return (try? repository.contributionPercents(in: budget)) ?? (30, nil)
    }
    /// Called on the family session. `forEveryone` changes the family default and drops the personal one.
    func setContributionPercent(_ percent: Int, forEveryone: Bool) throws {
        guard scope == .family, let repository, let budget = storedBudget else { throw LedgerError.unavailable }
        if forEveryone {
            try repository.setFamilyContributionPercent(percent, in: budget, asOf: referenceDate)
            refresh()
            guard let updated = storedBudget else { return }
            try repository.setMyContributionPercent(nil, in: updated, asOf: referenceDate)
        } else {
            try repository.setMyContributionPercent(percent, in: budget, asOf: referenceDate)
        }
        refresh()
    }
    /// What is still missing in envelopes due within a week.
    var urgentShortfalls: [Money] {
        envelopes.filter { daysUntil($0) <= 7 }
            .compactMap { try? $0.shortfall(balance: envelopeBalance($0)) }.filter { $0.minorUnits > 0 }
    }
    /// The default split of `incoming` into this budget's envelopes due this period.
    func distribution(of incoming: Money) -> EnvelopeDistribution {
        let end = household?.period.endExclusive ?? referenceDate.addingTimeInterval(30 * 86_400)
        let balances = Dictionary(uniqueKeysWithValues: envelopes.map { ($0.id, envelopeBalance($0)) })
        let days = max(1, (try? household?.period.remainingDays(including: referenceDate)) ?? 1)
        // Preserve at least today's guide, or one day of the new money for an unfunded plan.
        let oneDay = incoming.minorUnits / Int64(days) + (incoming.minorUnits % Int64(days) > 0 ? 1 : 0)
        let living = Money(minorUnits: max(0, result?.todayGuide.minorUnits ?? 0, oneDay), currency: incoming.currency)
        return (try? EnvelopeDistributor.distribute(incoming: incoming, envelopes: envelopes, balances: balances,
                                                    periodEnd: end, minimumLiving: living))
            ?? EnvelopeDistribution(incoming: incoming, fills: [:])
    }

    /// The default split of money already in the budget: urgent mandatory envelopes only, living days kept.
    func existingDistribution(of free: Money) -> EnvelopeDistribution {
        let end = household?.period.endExclusive ?? referenceDate
        let balances = Dictionary(uniqueKeysWithValues: envelopes.map { ($0.id, envelopeBalance($0)) })
        let guide = result?.todayGuide ?? Money(minorUnits: 0)
        return (try? EnvelopeDistributor.distributeExisting(free: free, envelopes: envelopes, balances: balances,
                    periodEnd: end, dailyGuide: guide, now: referenceDate, calendar: calendar))
            ?? EnvelopeDistribution(incoming: free, fills: [:])
    }

    /// Records that moved money in or out of one envelope, newest first.
    func envelopeHistory(_ envelope: RecurringEnvelope) -> [LedgerRecord] {
        historyRecords.filter { record in
            if case .reserve(let id) = record.transaction.funding { return id == envelope.id && !record.transaction.isDeleted }
            return false
        }.reversed()
    }

    /// Onboarding and new periods: `amount` to live on until `end` (the start of the first day after the period);
    /// later periods are extended by `rule`.
    func startBudget(amount: Money, until end: Date, rule: PeriodRule, operationID: UUID = UUID()) throws {
        guard amount.minorUnits > 0 else { throw BudgetError.invalidAmount }
        try ensureDailyPeriod()
        if let repository, let budget = storedBudget { try repository.setPeriodRule(rule, in: budget, asOf: referenceDate) }
        periodRule = rule
        if let budget = storedBudget { try setPeriodEnd(end, in: budget) }
        refresh()
        try addDailyFunds(amount, operationID: operationID)
    }

    func addPayment(id: UUID, name: String, amount: Money, dueDate: Date, reserveNow: Bool) throws {
        try ensureDailyPeriod()
        guard let result, amount.minorUnits > 0 else { throw BudgetError.invalidAmount }
        // Reopening onboarding after a partial save must not add the same envelope twice.
        if household?.reserves.contains(where: { $0.id == id }) == true { return }
        let reserve = ProtectedReserve(id: id, name: name, openingAmount: reserveNow ? amount : Money(minorUnits: 0),
            isRegularPayment: true, dueDate: dueDate, targetAmount: amount)
        let existing = (household?.reserves ?? [])
        guard let expected = storedBudget else { throw LedgerError.unavailable }
        try updateSalaryPlan(available: result.totalFunds, reserves: existing + [reserve], expected: expected)
    }

    var periodEnded: Bool { household.map { referenceDate >= $0.period.endExclusive } ?? false }
    var periodTitle: String {
        guard let period = household?.period else { return String(localized: "До зарплаты") }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = calendar.timeZone
        return period.start.formatted(style) + " — " + period.endExclusive.addingTimeInterval(-1).formatted(style)
    }
    func period(on date: Date) -> BudgetPeriod? {
        periods.first { $0.contains(date) } ?? periods.last { $0.start <= date }
    }
    func analytics(_ range: AnalyticsPeriod, on date: Date, through cutoff: Date? = nil) throws -> BudgetAnalyticsSnapshot {
        let stored = range == .month ? period(on: date) : nil
        let interval = stored.map { DateInterval(start: $0.start, end: $0.endExclusive) }
            ?? calendar.dateInterval(of: range == .day ? .day : range == .week ? .weekOfYear : .month, for: date)
        let anchor = cutoff ?? min(interval?.end.addingTimeInterval(-0.001) ?? date, referenceDate)
        return try BudgetAnalytics.calculate(records: historyRecords, period: range, anchor: anchor,
            asOf: referenceDate, calendar: calendar, catalog: catalog, budgetPeriod: stored)
    }
    func updateSalaryPlan(available: Money, reserves: [ProtectedReserve], expected: StoredBudget) throws {
        guard let repository else { throw LedgerError.unavailable }
        try repository.updateSalaryPlan(available: available, reserves: reserves, in: expected, asOf: referenceDate, balanceIsCurrent: true)
        refresh()
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
    func save(_ record: LedgerRecord, editing: LedgerRecord? = nil, addIncomeToPlan: Bool = false) throws {
        overviewCache = [:]
        let budget = try budget(editing: editing)
        let date = calculationDate(in: budget)
        if let repository {
            try repository.save(record, in: budget, expectedRevision: editing?.revision, asOf: date, addIncomeToPlan: addIncomeToPlan)
        } else {
            guard isDemo else { throw LedgerError.unavailable }
            let candidate = try LedgerRules.replacing(record, in: budget, asOf: date)
            let source = candidate.snapshot
            household = HouseholdSnapshot(id: source.id, period: source.period,
                monthlyFreePlan: addIncomeToPlan ? try source.monthlyFreePlan.adding(record.transaction.amount) : source.monthlyFreePlan,
                openingFunds: source.openingFunds, reserves: source.reserves, transactions: source.transactions)
            allRecords = candidate.records; historyRecords = candidate.records
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
                authorID: authorID, payerID: authorID), title: String(localized: "В семейный бюджет"), linkID: linkID)
            let into = LedgerRecord(transaction: TransactionSnapshot(amount: amount, kind: .contributionIn, date: referenceDate,
                authorID: familyAuthor, payerID: familyAuthor), title: String(localized: "Взнос в семейный бюджет"), linkID: linkID)
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
    /// Spends of the last 30 days, the base for the chips and the guess.
    private var recentExpenses: [LedgerRecord] {
        let since = referenceDate.addingTimeInterval(-30 * 86_400)
        return historyRecords.filter { $0.transaction.kind == .expense && !$0.transaction.isDeleted && $0.transaction.date >= since }
    }
    /// The three chips: most used in 30 days in a fixed order; a new user gets groceries, cafes, transport.
    func frequentCategories(limit: Int = 3) -> [SpendingCategory] {
        let selectable = catalog.selectable
        var counts: [UUID: Int] = [:]
        for record in recentExpenses { counts[record.categoryID, default: 0] += 1 }
        let used = selectable.filter { counts[$0.id] != nil && $0.id != BuiltInCategory.other.id }
            .sorted { counts[$0.id]! == counts[$1.id]! ? $0.name < $1.name : counts[$0.id]! > counts[$1.id]! }
        let defaults = [BuiltInCategory.groceries, .cafes, .transport].map(\.category).filter { selectable.contains($0) }
        var result: [SpendingCategory] = []
        for category in used + defaults where !result.contains(category) && result.count < limit { result.append(category) }
        return result
    }
    /// The chip picked in advance: the one most used around this hour (±1 h) among the chips.
    func likelyCategory(among chips: [SpendingCategory], at date: Date) -> SpendingCategory? {
        let hour = calendar.component(.hour, from: date)
        var counts: [UUID: Int] = [:]
        for record in recentExpenses {
            let other = calendar.component(.hour, from: record.transaction.date)
            if min(abs(other - hour), 24 - abs(other - hour)) <= 1 { counts[record.categoryID, default: 0] += 1 }
        }
        return chips.filter { counts[$0.id] != nil }.max { counts[$0.id]! < counts[$1.id]! } ?? chips.first
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
    func setBuiltInCategory(_ builtIn: BuiltInCategory, enabled: Bool) throws {
        guard let repository, let budget = storedBudget else { throw LedgerError.unavailable }
        try repository.setBuiltInCategory(builtIn, enabled: enabled, in: budget, asOf: referenceDate)
        refresh()
    }
    /// Own spends, refunds and top-ups; other members' records are read-only.
    func isEditable(_ record: LedgerRecord) -> Bool {
        [.expense, .refund, .income].contains(record.transaction.kind) && record.transaction.authorID == authorID
    }
    /// Only the contributor holds both sides, so only they can cancel a contribution.
    func canCancelContribution(_ record: LedgerRecord) -> Bool {
        record.linkID != nil && !isDemo && !record.transaction.isDeleted && record.transaction.authorID == authorID
    }
    func payerName(for record: LedgerRecord) -> String {
        memberName(record.transaction.payerID)
    }
    func memberName(_ id: UUID) -> String {
        guard let member = members.first(where: { $0.id == id }) else { return String(localized: "Участник") }
        guard !isDemo else { return member.name }
        if id == authorID { return String(localized: "Я") }
        return member.name == String(localized: "Я") ? String(localized: "Партнёр") : member.name
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
    /// Keypad text with thin-space thousands: "60000,5" → "60 000,5".
    static func grouped(_ text: String) -> String {
        let parts = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        var whole = String(parts.first ?? "")
        var groups: [String] = []
        while whole.count > 3 { groups.insert(String(whole.suffix(3)), at: 0); whole.removeLast(3) }
        groups.insert(whole, at: 0)
        return groups.joined(separator: "\u{2009}") + (parts.count > 1 ? "," + parts[1] : "")
    }
    static func parse(_ text: String) throws -> Money {
        try Money(parsing: text)
    }
}
