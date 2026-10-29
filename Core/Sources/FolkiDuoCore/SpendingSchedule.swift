import Foundation

/// An inclusive last spending day. The stored period still uses an exclusive end.
public enum SpendingSchedule: Equatable, Sendable {
    case monthEnd
    case dayOfMonth(Int)

    public func endExclusive(from now: Date, calendar: Calendar) throws -> Date {
        guard let month = calendar.dateInterval(of: .month, for: now) else { throw BudgetError.invalidPeriod }
        switch self {
        case .monthEnd: return month.end
        case .dayOfMonth(let day):
            guard (1...31).contains(day) else { throw BudgetError.invalidPeriod }
            var start = month.start
            for _ in 0..<2 {
                guard let range = calendar.range(of: .day, in: .month, for: start),
                      let last = calendar.date(byAdding: .day, value: min(day, range.count) - 1, to: start),
                      let end = calendar.date(byAdding: .day, value: 1, to: last) else { throw BudgetError.invalidPeriod }
                if end > now { return end }
                start = month.end
            }
            throw BudgetError.invalidPeriod
        }
    }
}

/// How a budget's period ends and how it is extended once it is over. Stored with the budget,
/// so every member's iPhone extends a shared period the same way.
public enum PeriodRule: Hashable, Sendable {
    /// Until the end of the calendar month.
    case monthEnd
    /// Up to and including this day of each month; short months use their last day.
    case dayOfMonth(Int)
    /// A fixed number of days, such as a week. Back-to-back periods keep the same weekday.
    case days(Int)

    /// "Месяц" from a start day: up to the day before the same date next month.
    public static func monthly(startingOn start: Date, calendar: Calendar) -> PeriodRule {
        let day = calendar.component(.day, from: start)
        return day == 1 ? .monthEnd : .dayOfMonth(day - 1)
    }

    /// "До зарплаты": payday itself starts the next period, so the last spending day is the day before.
    public static func payday(_ payday: Date, calendar: Calendar) -> PeriodRule {
        monthly(startingOn: payday, calendar: calendar)
    }

    /// For budgets started before the rule was stored: read it off the current period.
    /// A week stays a week, a period ending with its month stays monthly, any other end repeats on its date.
    public static func inferred(from period: BudgetPeriod) -> PeriodRule {
        let calendar = period.calendar
        let lastDay = calendar.startOfDay(for: period.endExclusive.addingTimeInterval(-1))
        let length = calendar.dateComponents([.day], from: calendar.startOfDay(for: period.start), to: period.endExclusive).day ?? 0
        if length == 7 { return .days(7) }
        if calendar.dateInterval(of: .month, for: lastDay)?.end == period.endExclusive { return .monthEnd }
        return .dayOfMonth(calendar.component(.day, from: lastDay))
    }

    /// The exclusive end of the period after `anchor`: the start of a new budget, or the end of the previous period.
    /// A fixed length counts from the anchor until it passes `now`; calendar rules ignore it.
    public func end(after anchor: Date, now: Date, calendar: Calendar) throws -> Date {
        switch self {
        case .monthEnd: return try SpendingSchedule.monthEnd.endExclusive(from: now, calendar: calendar)
        case .dayOfMonth(let day): return try SpendingSchedule.dayOfMonth(day).endExclusive(from: now, calendar: calendar)
        case .days(let length):
            guard (1...366).contains(length) else { throw BudgetError.invalidPeriod }
            var end = calendar.startOfDay(for: anchor)
            repeat {
                guard let next = calendar.date(byAdding: .day, value: length, to: end) else { throw BudgetError.invalidPeriod }
                end = next
            } while end <= now
            return end
        }
    }

    public var storageValue: String {
        switch self {
        case .monthEnd: "monthEnd"
        case .dayOfMonth(let day): "day:\(day)"
        case .days(let length): "days:\(length)"
        }
    }

    /// Nil for an unknown value, for example one written by a newer version of the app.
    public init?(storageValue: String) {
        if storageValue == "monthEnd" { self = .monthEnd; return }
        let parts = storageValue.split(separator: ":")
        guard parts.count == 2, let value = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "day" where (1...31).contains(value): self = .dayOfMonth(value)
        case "days" where (1...366).contains(value): self = .days(value)
        default: return nil
        }
    }
}
