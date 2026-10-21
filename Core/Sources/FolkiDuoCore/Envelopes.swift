import Foundation

/// A recurring payment with a fixed size and a day of the month: rent 25 000 on the 25th.
/// Its balance lives in the ledger as a reserve with the same identifier.
public struct RecurringEnvelope: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    /// The fixed amount of one payment.
    public let size: Money
    /// Day of the month, 1...31; short months use their last day.
    public let dueDay: Int
    /// Start of the day of the next payment.
    public let nextDue: Date
    /// A mandatory envelope must be full by its date; an optional one is a guide.
    public let isMandatory: Bool
    /// Payments are recorded under this category; nil means "Другое".
    public let categoryID: UUID?
    /// SF Symbol and colour of the envelope's icon; nil falls back to its category.
    public let symbol: String?
    public let color: CategoryColor?

    public init(id: UUID = UUID(), name: String, size: Money, dueDay: Int, nextDue: Date, isMandatory: Bool,
                categoryID: UUID? = nil, symbol: String? = nil, color: CategoryColor? = nil) throws {
        guard size.minorUnits > 0 else { throw BudgetError.invalidAmount }
        guard (1...31).contains(dueDay) else { throw BudgetError.invalidPeriod }
        self.id = id
        self.name = name
        self.size = size
        self.dueDay = dueDay
        self.nextDue = nextDue
        self.isMandatory = isMandatory
        self.categoryID = categoryID
        self.symbol = symbol
        self.color = color
    }

    /// The same envelope with other fields, for edits and moving to the next payment.
    public func with(name: String? = nil, size: Money? = nil, dueDay: Int? = nil, nextDue: Date? = nil,
                     isMandatory: Bool? = nil, symbol: String? = nil, color: CategoryColor? = nil) throws -> RecurringEnvelope {
        try RecurringEnvelope(id: id, name: name ?? self.name, size: size ?? self.size, dueDay: dueDay ?? self.dueDay,
                              nextDue: nextDue ?? self.nextDue, isMandatory: isMandatory ?? self.isMandatory, categoryID: categoryID,
                              symbol: symbol ?? self.symbol, color: color ?? self.color)
    }

    /// How much is still missing for the next payment, never negative.
    public func shortfall(balance: Money) throws -> Money {
        try size.subtracting(balance).nonnegative
    }
}

/// How loudly an envelope asks for money: by the days left until payment, only while it is short.
public enum EnvelopeUrgency: Equatable, Sendable, Comparable {
    /// Full: nothing to do.
    case funded
    /// Eight days or more: grey "still to collect".
    case calm
    /// Three to seven days: amber, a line on the main screen.
    case attention
    /// Two days or fewer, or overdue: red, one push.
    case serious
}

public enum EnvelopeSchedule {
    /// The `day` of the month containing `date`, clamped to the month's last day.
    public static func dueDate(day: Int, inMonthOf date: Date, calendar: Calendar) throws -> Date {
        guard (1...31).contains(day),
              let month = calendar.dateInterval(of: .month, for: date),
              let length = calendar.range(of: .day, in: .month, for: date)?.count,
              let due = calendar.date(byAdding: .day, value: min(day, length) - 1, to: month.start)
        else { throw BudgetError.invalidPeriod }
        return calendar.startOfDay(for: due)
    }

    /// The first payment on or after `date`: this month's day if it has not passed, otherwise next month's.
    public static func firstDue(day: Int, onOrAfter date: Date, calendar: Calendar) throws -> Date {
        let thisMonth = try dueDate(day: day, inMonthOf: date, calendar: calendar)
        if thisMonth >= calendar.startOfDay(for: date) { return thisMonth }
        guard let next = calendar.date(byAdding: .month, value: 1, to: thisMonth) else { throw BudgetError.invalidPeriod }
        return try dueDate(day: day, inMonthOf: next, calendar: calendar)
    }

    /// After a payment the envelope moves to the same day of the following month.
    public static func nextDue(after due: Date, day: Int, calendar: Calendar) throws -> Date {
        guard let next = calendar.date(byAdding: .month, value: 1, to: calendar.startOfDay(for: due)) else {
            throw BudgetError.invalidPeriod
        }
        return try dueDate(day: day, inMonthOf: next, calendar: calendar)
    }

    /// Whole days from today to the payment day; 0 on the day itself, negative when overdue.
    public static func daysUntil(_ due: Date, from now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
    }

    /// Fixed thresholds: 8+ days calm, 3–7 attention, 0–2 or overdue serious.
    public static func urgency(of envelope: RecurringEnvelope, balance: Money, now: Date, calendar: Calendar) throws -> EnvelopeUrgency {
        guard try envelope.shortfall(balance: balance).minorUnits > 0 else { return .funded }
        switch daysUntil(envelope.nextDue, from: now, calendar: calendar) {
        case ...2: return .serious
        case 3...7: return .attention
        default: return .calm
        }
    }
}

/// How one income is split: into envelopes first, the rest is money to live on.
public struct EnvelopeDistribution: Equatable, Sendable {
    public let incoming: Money
    /// Amount added to each envelope now; envelopes left out get nothing.
    public let fills: [UUID: Money]

    public init(incoming: Money, fills: [UUID: Money]) { self.incoming = incoming; self.fills = fills }

    /// What stays for everyday spending after the envelopes.
    public var living: Money {
        fills.values.reduce(incoming) { (try? $0.subtracting($1)) ?? $0 }
    }
}

public enum EnvelopeDistributor {
    /// The default split: envelopes due before the period ends, nearest first, each up to its shortfall.
    /// Envelopes due later wait for the next income.
    public static func distribute(incoming: Money, envelopes: [RecurringEnvelope], balances: [UUID: Money],
                                  periodEnd: Date) throws -> EnvelopeDistribution {
        guard incoming.minorUnits >= 0 else { throw BudgetError.invalidAmount }
        var left = incoming
        var fills: [UUID: Money] = [:]
        let due = envelopes.filter { $0.nextDue < periodEnd }
            .sorted { $0.nextDue != $1.nextDue ? $0.nextDue < $1.nextDue : $0.id.uuidString < $1.id.uuidString }
        for envelope in due where left.minorUnits > 0 {
            let need = try envelope.shortfall(balance: balance(of: envelope, in: balances))
            let fill = Money(minorUnits: min(need.minorUnits, left.minorUnits), currency: incoming.currency)
            guard fill.minorUnits > 0 else { continue }
            fills[envelope.id] = fill
            left = try left.subtracting(fill)
        }
        return EnvelopeDistribution(incoming: incoming, fills: fills)
    }

    /// A slider moved: the envelope gets `amount` now, clamped to 0...its shortfall and to what the other
    /// envelopes leave. Living money is the buffer; other envelopes keep their fills.
    public static func adjusting(_ distribution: EnvelopeDistribution, envelope: RecurringEnvelope,
                                 balance: Money, to amount: Money) throws -> EnvelopeDistribution {
        let need = try envelope.shortfall(balance: balance)
        let others = try distribution.fills.filter { $0.key != envelope.id }.values
            .reduce(Money(minorUnits: 0, currency: distribution.incoming.currency)) { try $0.adding($1) }
        let available = try distribution.incoming.subtracting(others).nonnegative
        let clamped = max(0, min(amount.minorUnits, need.minorUnits, available.minorUnits))
        var fills = distribution.fills
        fills[envelope.id] = clamped > 0 ? Money(minorUnits: clamped, currency: amount.currency) : nil
        return EnvelopeDistribution(incoming: distribution.incoming, fills: fills)
    }

    private static func balance(of envelope: RecurringEnvelope, in balances: [UUID: Money]) -> Money {
        balances[envelope.id] ?? Money(minorUnits: 0, currency: envelope.size.currency)
    }
}

/// The "В семью 30%" line of a personal top-up.
public enum ContributionAdvisor {
    /// A share of the top-up in whole units, raised by the shortfalls of family envelopes due within
    /// seven days, never more than the top-up itself.
    public static func suggestion(topUp: Money, percent: Int, urgentFamilyShortfalls: [Money]) throws -> Money {
        guard topUp.minorUnits >= 0, (0...100).contains(percent) else { throw BudgetError.invalidAmount }
        let share = Money(minorUnits: topUp.minorUnits * Int64(percent) / 100, currency: topUp.currency).roundedDownToWholeUnits
        let raised = try urgentFamilyShortfalls.reduce(share) { try $0.adding($1.nonnegative) }
        return Money(minorUnits: min(raised.minorUnits, topUp.minorUnits), currency: topUp.currency)
    }
}
