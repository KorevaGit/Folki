import Foundation

public enum AnalyticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month
    public var id: String { rawValue }
    public var title: String { switch self { case .day: String(localized: "День", bundle: .module); case .week: String(localized: "Неделя", bundle: .module); case .month: String(localized: "Период", bundle: .module) } }
}

public struct AnalyticsBucket: Identifiable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let expenses: Money
    public let refunds: Money
    public let isObserved: Bool
}

public struct CategorySpending: Identifiable, Sendable {
    public var id: UUID { categoryID }
    public let categoryID: UUID
    public let expenses: Money
    public let refunds: Money
}

public struct MemberContribution: Identifiable, Sendable {
    public var id: UUID { memberID }
    public let memberID: UUID
    public let amount: Money
}

public struct BudgetAnalyticsSnapshot: Sendable {
    public let interval: DateInterval
    public let cutoff: Date
    public let expenses: Money
    public let refunds: Money
    public let income: Money
    public let reserveTransfers: Money
    /// Personal budget: moved to the family. Family budget: received from members.
    public let contributions: Money
    /// Family budget only: who contributed how much, largest first.
    public let contributionsByMember: [MemberContribution]
    public let envelopeNetSpending: Money
    public let everydayCategories: [CategorySpending]
    public let envelopeCategories: [CategorySpending]
    public let flexibleNetSpending: Money
    /// Net spending split by the category's needs-versus-wants flag.
    public let essentialSpending: Money
    public let wantsSpending: Money
    public let recordCount: Int
    public let buckets: [AnalyticsBucket]
    public let categories: [CategorySpending]
    public var netSpending: Money { get throws { try expenses.subtracting(refunds) } }
}

public enum BudgetAnalytics {
    /// Calendar days/weeks, and stored payday bounds for the period view when supplied.
    /// No future/deleted records or transfer double counting.
    public static func calculate(records: [LedgerRecord], period: AnalyticsPeriod, anchor: Date,
                                 asOf now: Date, calendar: Calendar,
                                 catalog: CategoryCatalog = CategoryCatalog(), budgetPeriod: BudgetPeriod? = nil) throws -> BudgetAnalyticsSnapshot {
        var calendar = calendar
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        let component: Calendar.Component = switch period { case .day: .day; case .week: .weekOfYear; case .month: .month }
        let custom = period == .month ? budgetPeriod.map { DateInterval(start: $0.start, end: $0.endExclusive) } : nil
        guard let interval = custom ?? calendar.dateInterval(of: component, for: anchor),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: anchor)) else {
            throw BudgetError.invalidPeriod
        }
        let cutoff = min(now, nextDay.addingTimeInterval(-0.001), interval.end.addingTimeInterval(-0.001))
        let zero = Money(minorUnits: 0)
        var expenses = zero, refunds = zero, income = zero, transfers = zero, flexible = zero, contributions = zero
        var envelopeSpending = zero
        var everydayAmounts: [UUID: (Money, Money)] = [:], envelopeAmounts: [UUID: (Money, Money)] = [:]
        var byMember: [UUID: Money] = [:]
        var categoryAmounts: [UUID: (Money, Money)] = [:]
        var expenseBuckets: [Date: Money] = [:], refundBuckets: [Date: Money] = [:]
        var ids = Set<UUID>()
        var count = 0
        let bucketComponent: Calendar.Component = period == .day ? .hour : .day
        for record in records {
            let entry = record.transaction
            guard !entry.isDeleted, entry.date >= interval.start, entry.date < interval.end, entry.date <= cutoff else { continue }
            guard ids.insert(entry.id).inserted else { throw BudgetError.duplicateIdentifier }
            guard entry.amount.currency == .rub else { throw BudgetError.currencyMismatch }
            guard entry.amount.minorUnits > 0, let bucket = calendar.dateInterval(of: bucketComponent, for: entry.date)?.start else {
                throw BudgetError.invalidTransaction
            }
            count += 1
            switch entry.kind {
            case .expense, .refund:
                // A custom category that has not synced yet is shown as «Другое», not as a separate row.
                let categoryID = catalog.contains(record.categoryID) ? record.categoryID : BuiltInCategory.other.id
                let current = categoryAmounts[categoryID] ?? (zero, zero)
                if entry.kind == .expense {
                    expenses = try expenses.adding(entry.amount)
                    expenseBuckets[bucket] = try (expenseBuckets[bucket] ?? zero).adding(entry.amount)
                    categoryAmounts[categoryID] = (try current.0.adding(entry.amount), current.1)
                } else {
                    refunds = try refunds.adding(entry.amount)
                    refundBuckets[bucket] = try (refundBuckets[bucket] ?? zero).adding(entry.amount)
                    categoryAmounts[categoryID] = (current.0, try current.1.adding(entry.amount))
                }
                let fromEnvelope: Bool
                if case .reserve = entry.funding { fromEnvelope = true } else { fromEnvelope = false }
                var sourceAmount = (fromEnvelope ? envelopeAmounts[categoryID] : everydayAmounts[categoryID]) ?? (zero, zero)
                if entry.kind == .expense { sourceAmount.0 = try sourceAmount.0.adding(entry.amount) }
                else { sourceAmount.1 = try sourceAmount.1.adding(entry.amount) }
                if fromEnvelope {
                    envelopeAmounts[categoryID] = sourceAmount
                    envelopeSpending = try entry.kind == .expense ? envelopeSpending.adding(entry.amount) : envelopeSpending.subtracting(entry.amount)
                } else {
                    everydayAmounts[categoryID] = sourceAmount
                    flexible = try entry.kind == .expense ? flexible.adding(entry.amount) : flexible.subtracting(entry.amount)
                }
            case .income: income = try income.adding(entry.amount)
            case .reserveAllocation: transfers = try transfers.adding(entry.amount)
            case .reserveRelease: transfers = try transfers.subtracting(entry.amount)
            case .contributionOut: contributions = try contributions.adding(entry.amount)
            case .contributionIn:
                contributions = try contributions.adding(entry.amount)
                byMember[entry.payerID] = try (byMember[entry.payerID] ?? zero).adding(entry.amount)
            }
        }
        var buckets: [AnalyticsBucket] = []
        var cursor = calendar.dateInterval(of: bucketComponent, for: interval.start)?.start ?? interval.start
        while cursor < interval.end {
            buckets.append(AnalyticsBucket(start: cursor, expenses: expenseBuckets[cursor] ?? zero,
                                           refunds: refundBuckets[cursor] ?? zero, isObserved: cursor <= cutoff))
            guard let next = calendar.date(byAdding: bucketComponent, value: 1, to: cursor), next > cursor else {
                throw BudgetError.invalidPeriod
            }
            cursor = next
        }
        var categories: [CategorySpending] = []
        var essential = zero, wants = zero
        for (categoryID, amounts) in categoryAmounts {
            categories.append(CategorySpending(categoryID: categoryID, expenses: amounts.0, refunds: amounts.1))
            let net = try amounts.0.subtracting(amounts.1)
            if catalog.category(for: categoryID).isEssential { essential = try essential.adding(net) } else { wants = try wants.adding(net) }
        }
        categories.sort { left, right in
            if left.expenses.minorUnits == right.expenses.minorUnits { return left.categoryID.uuidString < right.categoryID.uuidString }
            return left.expenses.minorUnits > right.expenses.minorUnits
        }
        _ = try expenses.subtracting(refunds)
        let members = byMember.map { MemberContribution(memberID: $0.key, amount: $0.value) }.sorted { left, right in
            if left.amount.minorUnits == right.amount.minorUnits { return left.memberID.uuidString < right.memberID.uuidString }
            return left.amount.minorUnits > right.amount.minorUnits
        }
        func sourceCategories(_ amounts: [UUID: (Money, Money)]) -> [CategorySpending] {
            categories.compactMap { category in
                guard let value = amounts[category.categoryID] else { return nil }
                return CategorySpending(categoryID: category.categoryID, expenses: value.0, refunds: value.1)
            }
        }
        return BudgetAnalyticsSnapshot(interval: interval, cutoff: cutoff, expenses: expenses, refunds: refunds, income: income,
            reserveTransfers: transfers, contributions: contributions, contributionsByMember: members,
            envelopeNetSpending: envelopeSpending, everydayCategories: sourceCategories(everydayAmounts),
            envelopeCategories: sourceCategories(envelopeAmounts), flexibleNetSpending: flexible, essentialSpending: essential, wantsSpending: wants, recordCount: count, buckets: buckets, categories: categories)
    }
}
