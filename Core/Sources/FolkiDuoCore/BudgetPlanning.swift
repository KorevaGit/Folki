import Foundation

public enum PaymentRecurrence: String, CaseIterable, Identifiable, Sendable {
    case once, monthly, yearly
    public var id: String { rawValue }
    public var title: String { switch self { case .once: "Один раз"; case .monthly: "Ежемесячно"; case .yearly: "Ежегодно" } }
    public func next(after date: Date, calendar: Calendar, anchor: Date? = nil) -> Date? {
        guard self != .once, let start = calendar.dateInterval(of: .month, for: date)?.start,
              let next = calendar.date(byAdding: self == .monthly ? .month : .year, value: 1, to: start),
              let range = calendar.range(of: .day, in: .month, for: next) else { return nil }
        let desired = calendar.component(.day, from: anchor ?? date)
        let day = calendar.date(byAdding: .day, value: min(desired, range.count) - 1, to: next)!
        let time = calendar.dateComponents([.hour, .minute, .second], from: anchor ?? date)
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
    }
}

public enum SavingsPurpose: String, CaseIterable, Identifiable, Sendable {
    case goal, emergency, irregular
    public var id: String { rawValue }
    public var title: String { switch self { case .goal: "Цель"; case .emergency: "Подушка"; case .irregular: "Нерегулярные расходы" } }
}

public struct ObligationSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let amount: Money
    public let dueDate: Date
    public let recurrence: PaymentRecurrence
    public let category: ExpenseCategory
    public let reserved: Money
    public let paidAt: Date?
    public let cancelledAt: Date?
    public let revision: UUID
    public var isPending: Bool { paidAt == nil && cancelledAt == nil }
    public init(id: UUID, name: String, amount: Money, dueDate: Date, recurrence: PaymentRecurrence = .once,
                category: ExpenseCategory = .home, reserved: Money, paidAt: Date? = nil, cancelledAt: Date? = nil, revision: UUID) {
        self.id = id; self.name = name; self.amount = amount; self.dueDate = dueDate; self.recurrence = recurrence
        self.category = category; self.reserved = reserved; self.paidAt = paidAt; self.cancelledAt = cancelledAt; self.revision = revision
    }
}

public struct ExpectedIncomeSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let amount: Money
    public let dueDate: Date
    public let recurrence: PaymentRecurrence
    public let receivedAt: Date?
    public let cancelledAt: Date?
    public let revision: UUID
    public var isPending: Bool { receivedAt == nil && cancelledAt == nil }
    public init(id: UUID, name: String, amount: Money, dueDate: Date, recurrence: PaymentRecurrence = .once,
                receivedAt: Date? = nil, cancelledAt: Date? = nil, revision: UUID) {
        self.id = id; self.name = name; self.amount = amount; self.dueDate = dueDate; self.recurrence = recurrence
        self.receivedAt = receivedAt; self.cancelledAt = cancelledAt; self.revision = revision
    }
}

public struct CategoryLimitSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let category: ExpenseCategory
    public let amount: Money
    public let revision: UUID
    public init(id: UUID, category: ExpenseCategory, amount: Money, revision: UUID) {
        self.id = id; self.category = category; self.amount = amount; self.revision = revision
    }
}

public struct CashPlan: Sendable {
    public let nextIncome: ExpectedIncomeSnapshot?
    public let days: Int
    public let available: Money
    public let unreservedPayments: Money
    public let beforeIncome: Money
    public let dailyGuide: Money
    public let afterExpectedIncome: Money
}

public enum BudgetPlanning {
    /// Expected income never changes available cash; protected bills are already excluded from available.
    public static func forecast(available: Money, incomes: [ExpectedIncomeSnapshot], obligations: [ObligationSnapshot],
                                asOf now: Date, calendar: Calendar) throws -> CashPlan {
        let day = calendar.startOfDay(for: now)
        let next = incomes.filter(\.isPending).sorted { $0.dueDate < $1.dueDate }.first
        let end = next.map { max(day, calendar.startOfDay(for: $0.dueDate)) }
            ?? calendar.date(byAdding: .day, value: 30, to: day)!
        let days = max(1, calendar.dateComponents([.day], from: day, to: end).day ?? 1)
        var unpaid = Money(minorUnits: 0)
        for bill in obligations where bill.isPending && (bill.dueDate < end || calendar.isDate(bill.dueDate, inSameDayAs: day)) {
            let missing = try bill.amount.subtracting(bill.reserved).nonnegative
            unpaid = try unpaid.adding(missing)
        }
        let before = try available.subtracting(unpaid)
        let guide = try DailyAllocation(total: before.nonnegative, days: days).firstDayAmount
        return try CashPlan(nextIncome: next, days: days, available: available, unreservedPayments: unpaid,
            beforeIncome: before, dailyGuide: guide, afterExpectedIncome: before.adding(next?.amount ?? Money(minorUnits: 0)))
    }
    public static func suggestedContribution(goal: SavingsGoalSnapshot, asOf now: Date, calendar: Calendar) throws -> Money? {
        let remaining = try goal.target.subtracting(goal.balance).nonnegative
        guard remaining.minorUnits > 0 else { return nil }
        if let desired = goal.monthlyContribution { return Money(minorUnits: min(desired.minorUnits, remaining.minorUnits)) }
        guard let deadline = goal.deadline else { return nil }
        let start = calendar.dateInterval(of: .month, for: now)!.start
        let finish = calendar.dateInterval(of: .month, for: max(now, deadline))!.start
        let months = max(1, (calendar.dateComponents([.month], from: start, to: finish).month ?? 0) + 1)
        let divisor = Int64(months)
        return Money(minorUnits: remaining.minorUnits / divisor + (remaining.minorUnits % divisor == 0 ? 0 : 1))
    }
}

public struct SpendingComparison: Sendable {
    public let current: BudgetAnalyticsSnapshot
    public let previous: BudgetAnalyticsSnapshot
    public var change: Money { get throws { try current.netSpending.subtracting(previous.netSpending) } }
}

extension BudgetAnalytics {
    /// Match calendar days and wall-clock time, rather than comparing a partial period with a full one.
    public static func comparison(records: [LedgerRecord], period: AnalyticsPeriod, anchor: Date,
                                  asOf now: Date, calendar: Calendar) throws -> SpendingComparison {
        var calendar = calendar; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        var current = try calculate(records: records, period: period, anchor: anchor, asOf: now, calendar: calendar)
        let component: Calendar.Component = period == .month ? .month : period == .week ? .weekOfYear : .day
        guard let previousStart = calendar.date(byAdding: component, value: -1, to: current.interval.start),
              let previousInterval = calendar.dateInterval(of: component, for: previousStart) else { throw BudgetError.invalidPeriod }
        let elapsed = calendar.dateComponents([.day], from: current.interval.start, to: calendar.startOfDay(for: current.cutoff)).day ?? 0
        let count = calendar.dateComponents([.day], from: previousInterval.start, to: previousInterval.end).day ?? 1
        let comparisonDay = calendar.date(byAdding: .day, value: min(elapsed, count - 1), to: previousInterval.start)!
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: current.cutoff)
        let cutoff = min(calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: comparisonDay)!
            .addingTimeInterval(Double(time.nanosecond ?? 0) / 1_000_000_000), previousInterval.end.addingTimeInterval(-0.001))
        if elapsed >= count {
            let alignedDay = calendar.date(byAdding: .day, value: count - 1, to: current.interval.start)!
            let alignedCutoff = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: alignedDay)!
                .addingTimeInterval(Double(time.nanosecond ?? 0) / 1_000_000_000)
            current = try calculate(records: records, period: period, anchor: anchor, asOf: alignedCutoff, calendar: calendar)
        }
        let previous = try calculate(records: records, period: period, anchor: cutoff, asOf: cutoff, calendar: calendar)
        return SpendingComparison(current: current, previous: previous)
    }
}
