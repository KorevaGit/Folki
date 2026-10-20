import Foundation

public struct DailyBudgetSnapshot: Equatable, Sendable {
    public let day: Date
    public let remainingDays: Int
    public let todayGuide: Money
    public let todayNetSpending: Money
    public let todayRemaining: Money
    /// Flexible money, excluding every reserve. Legacy names also cover payday periods.
    public let monthlyRemaining: Money
    public let monthlyPlan: Money
    /// Spending ring totals: flexible money plus regular payments, excluding savings.
    public let periodRemaining: Money
    public let periodPlan: Money
    public let reserveBalances: [UUID: Money]
    public let futureAllocation: DailyAllocation?

    /// Floating point is used for drawing only, never for money or rounding.
    public var dayRingFraction: Double { fraction(todayRemaining, of: todayGuide) }
    public var monthRingFraction: Double { fraction(periodRemaining, of: periodPlan) }
    public var todayOverspending: Money {
        // A valid result cannot be Int64.min: guide is nonnegative and net spending
        // is checked before subtraction, so a representable deficit can be negated.
        Money(minorUnits: todayRemaining.minorUnits < 0 ? -todayRemaining.minorUnits : 0,
              currency: todayRemaining.currency)
    }

    private func fraction(_ amount: Money, of total: Money) -> Double {
        guard total.minorUnits > 0 else { return 0 }
        return max(0, min(1, Double(amount.minorUnits) / Double(total.minorUnits)))
    }
}

public enum DailyBudgetCalculator {
    public static func calculate(_ snapshot: HouseholdSnapshot, asOf now: Date) throws -> DailyBudgetSnapshot {
        let day = try snapshot.period.startOfDay(containing: now)
        let days = try snapshot.period.remainingDays(including: now)
        let currency = snapshot.monthlyFreePlan.currency
        guard snapshot.monthlyFreePlan.minorUnits >= 0,
              snapshot.monthlyFreePlan.minorUnits > 0 || !snapshot.reserves.isEmpty else { throw BudgetError.invalidPlan }
        guard snapshot.openingFunds.currency == currency else { throw BudgetError.currencyMismatch }
        var ledger = try Ledger(funds: snapshot.openingFunds, reserves: snapshot.reserves)
        var identifiers = Set<UUID>()
        var dayOpeningFree: Money?
        var todayStructuralChange = Money(minorUnits: 0, currency: currency)
        var todaySpending = Money(minorUnits: 0, currency: currency)
        let entries = snapshot.transactions.filter {
            !$0.isDeleted && snapshot.period.contains($0.date) && $0.date <= now
        }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            // Simultaneous reserve credits must be available to simultaneous debits,
            // regardless of UUID order or the order in which devices imported them.
            let lhs = reserveOrder($0), rhs = reserveOrder($1)
            if lhs != rhs { return lhs < rhs }
            return $0.id.uuidString < $1.id.uuidString
        }

        for entry in entries {
            guard identifiers.insert(entry.id).inserted else { throw BudgetError.duplicateIdentifier }
            guard entry.amount.currency == currency else { throw BudgetError.currencyMismatch }
            guard entry.amount.minorUnits > 0 else { throw BudgetError.invalidTransaction }
            let today = entry.date >= day
            if today && dayOpeningFree == nil { dayOpeningFree = try ledger.freeFunds() }
            let before = try ledger.freeFunds()
            try ledger.apply(entry)
            if today {
                switch (entry.kind, entry.funding) {
                case (.expense, .flexible): todaySpending = try todaySpending.adding(entry.amount)
                case (.refund, .flexible): todaySpending = try todaySpending.subtracting(entry.amount)
                default:
                    todayStructuralChange = try todayStructuralChange.adding(ledger.freeFunds().subtracting(before))
                }
            }
        }
        let free = try ledger.freeFunds()
        let opening = try (dayOpeningFree ?? free).adding(todayStructuralChange)
        let allocation = try DailyAllocation(total: opening.nonnegative, days: days)
        let guide = allocation.firstDayAmount
        let payments = snapshot.reserves.filter(\.isRegularPayment)
        let paymentPlan = try payments.reduce(Money(minorUnits: 0, currency: currency)) { try $0.adding($1.openingAmount) }
        let paymentBalance = try payments.reduce(Money(minorUnits: 0, currency: currency)) {
            try $0.adding(ledger.reserves[$1.id] ?? Money(minorUnits: 0, currency: currency))
        }
        return try DailyBudgetSnapshot(
            day: day, remainingDays: days, todayGuide: guide, todayNetSpending: todaySpending,
            todayRemaining: guide.subtracting(todaySpending), monthlyRemaining: free,
            monthlyPlan: snapshot.monthlyFreePlan,
            periodRemaining: free.adding(paymentBalance), periodPlan: snapshot.monthlyFreePlan.adding(paymentPlan),
            reserveBalances: ledger.reserves,
            futureAllocation: days > 1 ? DailyAllocation(total: free.nonnegative, days: days - 1) : nil
        )
    }

    private static func reserveOrder(_ entry: TransactionSnapshot) -> Int {
        guard case .reserve = entry.funding else { return 1 }
        switch entry.kind {
        case .income, .refund, .reserveAllocation, .contributionIn: return 0
        case .expense, .reserveRelease, .contributionOut: return 2
        }
    }
}

private struct Ledger {
    var funds: Money
    var reserves: [UUID: Money] = [:]
    var unallocated: Money

    init(funds: Money, reserves initial: [ProtectedReserve]) throws {
        self.funds = funds
        unallocated = Money(minorUnits: 0, currency: funds.currency)
        for reserve in initial {
            guard reserves[reserve.id] == nil else { throw BudgetError.duplicateIdentifier }
            guard reserve.openingAmount.currency == funds.currency else { throw BudgetError.currencyMismatch }
            guard reserve.openingAmount.minorUnits >= 0 else { throw BudgetError.invalidAmount }
            reserves[reserve.id] = reserve.openingAmount
        }
    }

    func freeFunds() throws -> Money {
        let protected = try reserves.values.reduce(Money(minorUnits: 0, currency: funds.currency)) { try $0.adding($1) }
        return try funds.subtracting(protected).subtracting(unallocated)
    }

    mutating func apply(_ entry: TransactionSnapshot) throws {
        switch entry.kind {
        case .expense, .refund:
            guard entry.funding != .unallocated else { throw BudgetError.invalidTransaction }
            if entry.kind == .expense {
                funds = try funds.subtracting(entry.amount)
            } else {
                funds = try funds.adding(entry.amount)
            }
            if case .reserve(let id) = entry.funding {
                try changeReserve(id, by: entry.amount, increasing: entry.kind == .refund)
            }
        case .income:
            funds = try funds.adding(entry.amount)
            switch entry.funding {
            case .flexible: break // Explicit allocation to the spending plan.
            case .unallocated: unallocated = try unallocated.adding(entry.amount)
            case .reserve(let id): try changeReserve(id, by: entry.amount, increasing: true)
            }
        case .reserveAllocation, .reserveRelease:
            guard case .reserve(let id) = entry.funding else { throw BudgetError.invalidTransaction }
            try changeReserve(id, by: entry.amount, increasing: entry.kind == .reserveAllocation)
        case .contributionOut, .contributionIn:
            guard entry.funding == .flexible else { throw BudgetError.invalidTransaction }
            funds = try entry.kind == .contributionIn ? funds.adding(entry.amount) : funds.subtracting(entry.amount)
        }
    }

    mutating func changeReserve(_ id: UUID, by amount: Money, increasing: Bool) throws {
        guard let current = reserves[id] else { throw BudgetError.missingReserve }
        if !increasing && amount.minorUnits > current.minorUnits { throw BudgetError.insufficientReserve }
        reserves[id] = try increasing ? current.adding(amount) : current.subtracting(amount)
    }
}

extension DailyBudgetSnapshot {
    /// What one operation costs the rest of the month: the daily amount after it minus the daily amount
    /// before it (`before`). A 500 purchase with 10 days left gives −50. Nil on the last day.
    public func nextDaysChange(since before: DailyBudgetSnapshot) throws -> Money? {
        guard let futureAllocation, let previous = before.futureAllocation else { return nil }
        return try futureAllocation.firstDayAmount.subtracting(previous.firstDayAmount)
    }
}

public struct PurchaseImpact: Equatable, Sendable {
    public let todayRemaining: Money
    public let monthlyRemaining: Money
    public let futureAllocation: DailyAllocation?
}

public enum PurchaseImpactCalculator {
    /// A preview is not a ledger entry and does not mutate the source snapshot.
    public static func preview(amount: Money, against snapshot: DailyBudgetSnapshot) throws -> PurchaseImpact {
        guard amount.minorUnits > 0 else { throw BudgetError.invalidAmount }
        // Preview must reject the same aggregate overflow as an actual ledger write.
        _ = try snapshot.todayNetSpending.adding(amount)
        let month = try snapshot.monthlyRemaining.subtracting(amount)
        return try PurchaseImpact(
            todayRemaining: snapshot.todayRemaining.subtracting(amount), monthlyRemaining: month,
            futureAllocation: snapshot.remainingDays > 1 ? DailyAllocation(total: month.nonnegative, days: snapshot.remainingDays - 1) : nil
        )
    }
}
