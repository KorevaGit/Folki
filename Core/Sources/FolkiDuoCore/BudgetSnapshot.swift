import Foundation

public struct ProtectedReserve: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let openingAmount: Money
    /// Regular bills belong to the period's spending ring, but never the daily allowance.
    public let isRegularPayment: Bool
    public let dueDate: Date?
    public let targetAmount: Money?

    public init(id: UUID = UUID(), name: String, openingAmount: Money, isRegularPayment: Bool = false, dueDate: Date? = nil, targetAmount: Money? = nil) {
        self.id = id
        self.name = name
        self.openingAmount = openingAmount
        self.isRegularPayment = isRegularPayment
        self.dueDate = dueDate; self.targetAmount = targetAmount
    }
}

public enum TransactionKind: Equatable, Sendable {
    case expense, refund, income, reserveAllocation, reserveRelease
    /// Money moved from a member's personal budget into the family budget.
    /// Recorded twice with one shared link: out of the personal budget, into the family one.
    /// Neither side is spending.
    case contributionOut, contributionIn

    public var isContribution: Bool { self == .contributionOut || self == .contributionIn }
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
