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
