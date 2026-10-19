import Foundation

public enum BudgetScope: String, CaseIterable, Identifiable, Sendable {
    case personal, family
    public var id: String { rawValue }
    public var title: String { self == .personal ? "Личный" : "Семейный" }
    public var savingsTitle: String { self == .personal ? "Личные накопления" : "Семейные накопления" }
    /// The direction a contribution takes in a budget of this scope.
    public var contributionKind: TransactionKind { self == .personal ? .contributionOut : .contributionIn }
}

public struct SavingsGoalSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let target: Money
    public let balance: Money
    public init(id: UUID, name: String, target: Money, balance: Money) {
        self.id = id; self.name = name; self.target = target; self.balance = balance
    }
    public var fraction: Double {
        guard target.minorUnits > 0 else { return 0 }
        return min(1, max(0, Double(balance.minorUnits) / Double(target.minorUnits)))
    }
}

public struct Member: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let isActive: Bool
    public init(id: UUID, name: String, isActive: Bool = true) { self.id = id; self.name = name; self.isActive = isActive }
}

public enum ExpenseCategory: String, CaseIterable, Sendable {
    case groceries, transport, home, health, leisure, other
    public var title: String {
        switch self {
        case .groceries: "Продукты"
        case .transport: "Транспорт"
        case .home: "Дом"
        case .health: "Здоровье"
        case .leisure: "Досуг"
        case .other: "Другое"
        }
    }
    public var symbol: String {
        switch self {
        case .groceries: "basket.fill"
        case .transport: "tram.fill"
        case .home: "house.fill"
        case .health: "heart.fill"
        case .leisure: "sparkles"
        case .other: "receipt.fill"
        }
    }
}

public struct LedgerRecord: Identifiable, Sendable {
    public let transaction: TransactionSnapshot
    public let title: String
    public let category: ExpenseCategory
    public let revision: UUID
    public let symbol: String
    /// Shared by both sides of a contribution; nil for every other operation.
    public let linkID: UUID?
    public var id: UUID { transaction.id }
    public init(transaction: TransactionSnapshot, title: String, symbol: String? = nil,
                category: ExpenseCategory = .other, revision: UUID = UUID(), linkID: UUID? = nil) {
        self.transaction = transaction; self.title = title; self.category = category
        self.revision = revision; self.linkID = linkID
        self.symbol = symbol ?? (transaction.kind.isContribution ? "person.2.fill"
            : [.reserveAllocation, .reserveRelease].contains(transaction.kind) ? "arrow.left.arrow.right" : category.symbol)
    }
}

public struct StoredBudget: Sendable {
    public let scope: BudgetScope
    public let snapshot: HouseholdSnapshot
    public let periodID: UUID
    public let members: [Member]
    public let records: [LedgerRecord]
    public init(snapshot: HouseholdSnapshot, periodID: UUID, members: [Member], records: [LedgerRecord], scope: BudgetScope = .family) {
        self.scope = scope
        self.snapshot = snapshot; self.periodID = periodID; self.members = members; self.records = records
    }
}

public enum LedgerError: Error, Equatable {
    case unavailable, corruptStore, conflict, missingRecord, invalidMember, existingPeriod, multipleHouseholds
    case cloudNotConfigured, accessDenied, accountChanged, privateBudgetCannotBeShared, familyFull
}

public enum LedgerRules {
    /// Replace the original operation for previews and edits; never add the old amount twice.
    public static func replacing(_ record: LedgerRecord, in budget: StoredBudget, asOf now: Date) throws -> StoredBudget {
        let entry = record.transaction
        guard !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.amount.minorUnits > 0, entry.amount.currency == .rub,
              budget.snapshot.period.contains(entry.date), entry.date <= now,
              entry.kind.isContribution == (record.linkID != nil),
              !entry.kind.isContribution || entry.kind == budget.scope.contributionKind else { throw BudgetError.invalidTransaction }
        guard budget.members.contains(where: { $0.id == entry.payerID }),
              budget.members.contains(where: { $0.id == entry.authorID }) else { throw LedgerError.invalidMember }
        var records = budget.records.filter { $0.id != record.id }
        records.append(record)
        let source = budget.snapshot
        let snapshot = HouseholdSnapshot(id: source.id, period: source.period,
            monthlyFreePlan: source.monthlyFreePlan, openingFunds: source.openingFunds,
            reserves: source.reserves, transactions: records.map(\.transaction))
        _ = try DailyBudgetCalculator.calculate(snapshot, asOf: now)
        return StoredBudget(snapshot: snapshot, periodID: budget.periodID, members: budget.members, records: records, scope: budget.scope)
    }
}
