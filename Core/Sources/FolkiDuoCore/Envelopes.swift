import Foundation

/// A recurring payment with an estimated amount and a day of the month: rent 25 000 on the 25th.
/// Its balance lives in the ledger as a reserve with the same identifier.
public struct RecurringEnvelope: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    /// Expected amount of one payment; the actual expense may be smaller or larger.
    public let size: Money
    /// Day of the month, 1...31; short months use their last day.
    public let dueDay: Int
    /// Start of the day of the next payment.
    public let nextDue: Date
    /// A mandatory payment has priority when distributing money; size is a forecast, not a minimum.
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

/// How one income is split between envelopes and money to live on.
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
    /// Keep the caller's daily reserve, then share the rest proportionally to each shortfall.
    /// Envelopes due later wait for the next income. Largest remainders preserve every kopeck.
    public static func distribute(incoming: Money, envelopes: [RecurringEnvelope], balances: [UUID: Money],
                                  periodEnd: Date, minimumLiving: Money = Money(minorUnits: 0)) throws -> EnvelopeDistribution {
        guard incoming.minorUnits >= 0, minimumLiving.minorUnits >= 0 else { throw BudgetError.invalidAmount }
        guard incoming.currency == minimumLiving.currency else { throw BudgetError.currencyMismatch }
        let due = envelopes.filter { $0.nextDue < periodEnd }
        guard Set(due.map(\.id)).count == due.count else { throw BudgetError.duplicateIdentifier }
        var needs: [(id: UUID, amount: Int64)] = []
        var total = Money(minorUnits: 0, currency: incoming.currency)
        for envelope in due {
            let need = try envelope.shortfall(balance: balance(of: envelope, in: balances))
            total = try total.adding(need)
            if need.minorUnits > 0 { needs.append((envelope.id, need.minorUnits)) }
        }
        let available = max(0, incoming.minorUnits - min(incoming.minorUnits, minimumLiving.minorUnits))
        let pool = min(available, total.minorUnits)
        guard pool > 0 else { return EnvelopeDistribution(incoming: incoming, fills: [:]) }
        var fills: [UUID: Money] = [:]
        var remainders: [(id: UUID, remainder: UInt64)] = []
        var allocated: Int64 = 0
        for need in needs {
            // Full-width arithmetic avoids overflowing large valid money amounts.
            let product = UInt64(pool).multipliedFullWidth(by: UInt64(need.amount))
            let share = UInt64(total.minorUnits).dividingFullWidth(product)
            let amount = Int64(share.quotient)
            if amount > 0 { fills[need.id] = Money(minorUnits: amount, currency: incoming.currency) }
            allocated += amount
            remainders.append((need.id, share.remainder))
        }
        remainders.sort { $0.remainder != $1.remainder ? $0.remainder > $1.remainder : $0.id.uuidString < $1.id.uuidString }
        for item in remainders.prefix(Int(pool - allocated)) {
            fills[item.id] = Money(minorUnits: (fills[item.id]?.minorUnits ?? 0) + 1, currency: incoming.currency)
        }
        return EnvelopeDistribution(incoming: incoming, fills: fills)
    }

    /// Money already in the budget, not a new income: it has to last the rest of the period.
    /// Only mandatory envelopes due within a week are filled by default (later ones wait for the next income),
    /// and the days until the last of those payments keep `dailyGuide` each, so funding a bill early
    /// never empties the days before it. Optional envelopes stay at zero until the user moves their slider.
    public static func distributeExisting(free: Money, envelopes: [RecurringEnvelope], balances: [UUID: Money],
                                          periodEnd: Date, dailyGuide: Money, now: Date, calendar: Calendar) throws -> EnvelopeDistribution {
        guard free.minorUnits >= 0, dailyGuide.minorUnits >= 0 else { throw BudgetError.invalidAmount }
        let urgent = try envelopes.filter { envelope in
            let days = EnvelopeSchedule.daysUntil(envelope.nextDue, from: now, calendar: calendar)
            guard envelope.isMandatory, envelope.nextDue < periodEnd, days <= 7 else { return false }
            return try envelope.shortfall(balance: balance(of: envelope, in: balances)).minorUnits > 0
        }
        guard !urgent.isEmpty else { return EnvelopeDistribution(incoming: free, fills: [:]) }
        let days = urgent.map { max(1, EnvelopeSchedule.daysUntil($0.nextDue, from: now, calendar: calendar)) }.max() ?? 1
        let keep = dailyGuide.minorUnits.multipliedReportingOverflow(by: Int64(days))
        guard !keep.overflow else { throw BudgetError.amountOverflow }
        return try distribute(incoming: free, envelopes: urgent, balances: balances, periodEnd: periodEnd,
                              minimumLiving: Money(minorUnits: keep.partialValue, currency: free.currency))
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

/// One preview and validation path for an income, its family share and envelope allocations.
public enum FundingPlan {
    public static func applying(to source: HouseholdSnapshot, incoming: Money, fills: [UUID: Money],
                                familyShare: Money, now: Date, author: UUID, operationID: UUID) throws -> HouseholdSnapshot {
        guard incoming.minorUnits > 0, familyShare.minorUnits >= 0 else { throw BudgetError.invalidAmount }
        var allocated = familyShare
        for (id, fill) in fills {
            guard fill.minorUnits > 0, source.reserves.contains(where: { $0.id == id }) else { throw BudgetError.missingReserve }
            allocated = try allocated.adding(fill)
        }
        guard allocated.currency == incoming.currency, allocated.minorUnits <= incoming.minorUnits else { throw BudgetError.insufficientReserve }
        var transactions = source.transactions
        transactions.append(TransactionSnapshot(id: operationID, amount: incoming, kind: .income, funding: .flexible,
            date: now, authorID: author, payerID: author))
        if familyShare.minorUnits > 0 {
            transactions.append(TransactionSnapshot(amount: familyShare, kind: .contributionOut, date: now, authorID: author, payerID: author))
        }
        for (id, fill) in fills.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            transactions.append(TransactionSnapshot(amount: fill, kind: .reserveAllocation, funding: .reserve(id),
                date: now, authorID: author, payerID: author))
        }
        let snapshot = HouseholdSnapshot(id: source.id, period: source.period,
            monthlyFreePlan: try source.monthlyFreePlan.adding(incoming), openingFunds: source.openingFunds,
            reserves: source.reserves, transactions: transactions)
        _ = try DailyBudgetCalculator.calculate(snapshot, asOf: now)
        return snapshot
    }
}
