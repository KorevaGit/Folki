import Foundation

/// A forecast, independent of ledger money. One day of the estimated income stays available for living.
public struct StarterAllocation: Equatable, Sendable {
    public let income: Money
    public let days: Int
    public let amounts: [UUID: Money]
    public var minimumLiving: Money {
        Money(minorUnits: income.minorUnits / Int64(days) + (income.minorUnits % Int64(days) > 0 ? 1 : 0), currency: income.currency)
    }
    public var living: Money {
        Money(minorUnits: income.minorUnits - amounts.values.reduce(0) { $0 + $1.minorUnits }, currency: income.currency)
    }
    public var daily: Money { (try? DailyAllocation(total: living, days: days).firstDayAmount) ?? Money(minorUnits: 0, currency: income.currency) }

    public init(income: Money, days: Int, amounts: [UUID: Money]) throws {
        guard income.minorUnits > 0, days > 0 else { throw BudgetError.invalidAmount }
        let reserve = income.minorUnits / Int64(days) + (income.minorUnits % Int64(days) > 0 ? 1 : 0)
        var total = Money(minorUnits: 0, currency: income.currency)
        for amount in amounts.values {
            guard amount.minorUnits >= 0 else { throw BudgetError.invalidAmount }
            total = try total.adding(amount)
        }
        guard total.minorUnits <= income.minorUnits - reserve else { throw BudgetError.insufficientReserve }
        self.income = income; self.days = days; self.amounts = amounts
    }

    public static func suggested(income: Money, days: Int, percentages: [UUID: Int]) throws -> StarterAllocation {
        guard income.minorUnits > 0, days > 0, percentages.values.allSatisfy({ (0...100).contains($0) }) else { throw BudgetError.invalidAmount }
        let weight = percentages.values.reduce(0, +)
        guard weight <= 100 else { throw BudgetError.invalidPlan }
        let reserve = income.minorUnits / Int64(days) + (income.minorUnits % Int64(days) > 0 ? 1 : 0)
        let pool = income.minorUnits - reserve
        let proposed = percentages.mapValues { percent in
            income.minorUnits / 100 * Int64(percent) + income.minorUnits % 100 * Int64(percent) / 100
        }
        let total = proposed.values.reduce(Int64(0), +)
        let amounts = proposed.mapValues { value in
            let bounded: Int64
            if total > pool, total > 0 {
                bounded = Int64(UInt64(total).dividingFullWidth(UInt64(pool).multipliedFullWidth(by: UInt64(value))).quotient)
            } else { bounded = value }
            return Money(minorUnits: bounded, currency: income.currency)
        }
        return try StarterAllocation(income: income, days: days, amounts: amounts)
    }

    public func maximum(for id: UUID) -> Money {
        let others = amounts.filter { $0.key != id }.values.reduce(Int64(0)) { $0 + $1.minorUnits }
        return Money(minorUnits: max(0, income.minorUnits - minimumLiving.minorUnits - others), currency: income.currency)
    }

    public func adjusting(_ id: UUID, to amount: Money) throws -> StarterAllocation {
        guard amounts[id] != nil else { throw BudgetError.missingReserve }
        guard amount.currency == income.currency else { throw BudgetError.currencyMismatch }
        var next = amounts
        next[id] = Money(minorUnits: max(0, min(amount.minorUnits, maximum(for: id).minorUnits)), currency: income.currency)
        return try StarterAllocation(income: income, days: days, amounts: next)
    }
}
