import Foundation

public struct BudgetPeriod: Equatable, Sendable {
    public let start: Date
    public let endExclusive: Date
    public let timeZoneIdentifier: String

    public init(monthContaining date: Date, timeZoneIdentifier: String) throws {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { throw BudgetError.invalidTimeZone }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let interval = calendar.dateInterval(of: .month, for: date) else { throw BudgetError.invalidPeriod }
        start = interval.start
        endExclusive = interval.end
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // This identifier is validated by the only public initializer.
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < endExclusive }

    public func startOfDay(containing date: Date) throws -> Date {
        guard contains(date) else { throw BudgetError.dateOutsidePeriod }
        return calendar.startOfDay(for: date)
    }

    public func remainingDays(including date: Date) throws -> Int {
        let day = try startOfDay(containing: date)
        guard let days = calendar.dateComponents([.day], from: day, to: endExclusive).day, days > 0 else {
            throw BudgetError.invalidPeriod
        }
        return days
    }
}

public enum BudgetPeriodResolver {
    public static func month(containing date: Date, timeZoneIdentifier: String) throws -> BudgetPeriod {
        try BudgetPeriod(monthContaining: date, timeZoneIdentifier: timeZoneIdentifier)
    }
}
