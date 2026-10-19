import Foundation

public enum AnalyticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month
    public var id: String { rawValue }
    public var title: String { switch self { case .day: "День"; case .week: "Неделя"; case .month: "Месяц" } }
}

public struct AnalyticsBucket: Identifiable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let expenses: Money
    public let refunds: Money
    public let isObserved: Bool
}

public struct CategorySpending: Identifiable, Sendable {
    public var id: ExpenseCategory { category }
    public let category: ExpenseCategory
    public let expenses: Money
    public let refunds: Money
}

public struct BudgetAnalyticsSnapshot: Sendable {
    public let interval: DateInterval
    public let cutoff: Date
    public let expenses: Money
    public let refunds: Money
    public let income: Money
    public let reserveTransfers: Money
    public let flexibleNetSpending: Money
    public let recordCount: Int
    public let buckets: [AnalyticsBucket]
    public let categories: [CategorySpending]
    public var netSpending: Money { get throws { try expenses.subtracting(refunds) } }
}

public enum BudgetAnalytics {
    /// Calendar periods, Monday-first weeks, no future/deleted records or transfer double counting.
    public static func calculate(records: [LedgerRecord], period: AnalyticsPeriod, anchor: Date,
                                 asOf now: Date, calendar: Calendar) throws -> BudgetAnalyticsSnapshot {
        var calendar = calendar
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        let component: Calendar.Component = switch period { case .day: .day; case .week: .weekOfYear; case .month: .month }
        guard let interval = calendar.dateInterval(of: component, for: anchor),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: anchor)) else {
            throw BudgetError.invalidPeriod
        }
        let cutoff = min(now, nextDay.addingTimeInterval(-0.001), interval.end.addingTimeInterval(-0.001))
        let zero = Money(minorUnits: 0)
        var expenses = zero, refunds = zero, income = zero, transfers = zero, flexible = zero
        var categoryAmounts: [ExpenseCategory: (Money, Money)] = [:]
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
                let current = categoryAmounts[record.category] ?? (zero, zero)
                if entry.kind == .expense {
                    expenses = try expenses.adding(entry.amount)
                    expenseBuckets[bucket] = try (expenseBuckets[bucket] ?? zero).adding(entry.amount)
                    categoryAmounts[record.category] = (try current.0.adding(entry.amount), current.1)
                } else {
                    refunds = try refunds.adding(entry.amount)
                    refundBuckets[bucket] = try (refundBuckets[bucket] ?? zero).adding(entry.amount)
                    categoryAmounts[record.category] = (current.0, try current.1.adding(entry.amount))
                }
                if entry.funding == .flexible {
                    flexible = try entry.kind == .expense ? flexible.adding(entry.amount) : flexible.subtracting(entry.amount)
                }
            case .income: income = try income.adding(entry.amount)
            case .reserveAllocation: transfers = try transfers.adding(entry.amount)
            case .reserveRelease: transfers = try transfers.subtracting(entry.amount)
            }
        }
        var buckets: [AnalyticsBucket] = []
        var cursor = interval.start
        while cursor < interval.end {
            buckets.append(AnalyticsBucket(start: cursor, expenses: expenseBuckets[cursor] ?? zero,
                                           refunds: refundBuckets[cursor] ?? zero, isObserved: cursor <= cutoff))
            guard let next = calendar.date(byAdding: bucketComponent, value: 1, to: cursor), next > cursor else {
                throw BudgetError.invalidPeriod
            }
            cursor = next
        }
        var categories: [CategorySpending] = []
        for (category, amounts) in categoryAmounts {
            categories.append(CategorySpending(category: category, expenses: amounts.0, refunds: amounts.1))
        }
        categories.sort { left, right in
            if left.expenses.minorUnits == right.expenses.minorUnits { return left.category.rawValue < right.category.rawValue }
            return left.expenses.minorUnits > right.expenses.minorUnits
        }
        _ = try expenses.subtracting(refunds)
        return BudgetAnalyticsSnapshot(interval: interval, cutoff: cutoff, expenses: expenses, refunds: refunds, income: income,
            reserveTransfers: transfers, flexibleNetSpending: flexible, recordCount: count, buckets: buckets, categories: categories)
    }
}
