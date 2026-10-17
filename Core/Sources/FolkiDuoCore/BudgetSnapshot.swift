import Foundation

public struct ProtectedReserve: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let openingAmount: Money

    public init(id: UUID = UUID(), name: String, openingAmount: Money) {
        self.id = id
        self.name = name
        self.openingAmount = openingAmount
    }
}

public enum TransactionKind: Equatable, Sendable {
    case expense, refund, income, reserveAllocation, reserveRelease
}

public enum BudgetFunding: Equatable, Sendable {
    case flexible
    case reserve(UUID)
    /// Received income not yet explicitly assigned to the spending plan.
    case unallocated
}

public struct TransactionSnapshot: Sendable, Identifiable {
    public let id: UUID
    public let amount: Money
    public let kind: TransactionKind
    public let funding: BudgetFunding
    public let date: Date
    public let authorID: UUID
    public let payerID: UUID
    public let isDeleted: Bool

    public init(id: UUID = UUID(), amount: Money, kind: TransactionKind, funding: BudgetFunding? = nil,
                date: Date, authorID: UUID, payerID: UUID, isDeleted: Bool = false) {
        self.id = id
        self.amount = amount
        self.kind = kind
        self.funding = funding ?? (kind == .income ? .unallocated : .flexible)
        self.date = date
        self.authorID = authorID
        self.payerID = payerID
        self.isDeleted = isDeleted
    }
}

/// Opening funds and reserves are a period-start snapshot; operations follow it.
/// The bank is not consulted: all values come from the user's ledger.
public struct HouseholdSnapshot: Sendable {
    public let id: UUID
    public let period: BudgetPeriod
    public let monthlyFreePlan: Money
    public let openingFunds: Money
    public let reserves: [ProtectedReserve]
    public let transactions: [TransactionSnapshot]

    public init(id: UUID = UUID(), period: BudgetPeriod, monthlyFreePlan: Money, openingFunds: Money,
                reserves: [ProtectedReserve] = [], transactions: [TransactionSnapshot] = []) {
        self.id = id
        self.period = period
        self.monthlyFreePlan = monthlyFreePlan
        self.openingFunds = openingFunds
        self.reserves = reserves
        self.transactions = transactions
    }
}

public struct GoalContribution: Sendable, Identifiable {
    public enum Direction: Sendable { case contribution, withdrawal }
    public let id: UUID
    public let goalID: UUID
    public let memberID: UUID
    public let amount: Money
    public let direction: Direction
    public let date: Date

    public init(id: UUID = UUID(), goalID: UUID, memberID: UUID, amount: Money, direction: Direction, date: Date) throws {
        guard amount.minorUnits > 0 else { throw BudgetError.invalidAmount }
        self.id = id
        self.goalID = goalID
        self.memberID = memberID
        self.amount = amount
        self.direction = direction
        self.date = date
    }
}
