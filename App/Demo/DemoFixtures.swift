#if FOLKI_DEMO
import Foundation
import FolkiDuoCore

/// Excluded by conditional compilation from Debug/Release product code.
enum DemoFixtures {
    private static let mashaID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let sashaID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let mashaContribution = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!

    @MainActor static func makePersonalSession() -> BudgetSession {
        let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
        let owner = Member(id: mashaID, name: "Маша")
        let records = [
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 1_000_000), kind: .contributionOut,
                date: now.addingTimeInterval(-86400 * 10), authorID: owner.id, payerID: owner.id), title: "В семейный бюджет", linkID: mashaContribution),
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 4_000_000), kind: .expense,
                date: now.addingTimeInterval(-86400), authorID: owner.id, payerID: owner.id), title: "Ранее в месяце"),
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 80_000), kind: .expense,
                date: now.addingTimeInterval(-60), authorID: owner.id, payerID: owner.id), title: "Обед", categoryID: BuiltInCategory.cafes.id)
        ]
        let period = try! BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow")
        let snapshot = HouseholdSnapshot(period: period, monthlyFreePlan: Money(minorUnits: 6_000_000),
            openingFunds: Money(minorUnits: 6_000_000), transactions: records.map(\.transaction))
        return BudgetSession(scope: .personal, household: snapshot, records: records, members: [owner], demoDate: now)
    }

    @MainActor static func makeSession() -> BudgetSession {
        let masha = Member(id: mashaID, name: "Маша")
        let sasha = Member(id: sashaID, name: "Саша")
        let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
        let previous = ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!
        let records = [
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 1_000_000), kind: .contributionIn,
                date: now.addingTimeInterval(-86400 * 10), authorID: masha.id, payerID: masha.id), title: "Взнос в семейный бюджет", linkID: mashaContribution),
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 800_000), kind: .contributionIn,
                date: now.addingTimeInterval(-86400 * 9), authorID: sasha.id, payerID: sasha.id), title: "Взнос в семейный бюджет", linkID: UUID()),
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 7_845_000), kind: .expense,
                date: previous, authorID: masha.id, payerID: masha.id), title: "Расходы ранее в октябре"),
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 105_000), kind: .expense,
                date: now.addingTimeInterval(-1800), authorID: masha.id, payerID: masha.id), title: "Продукты к ужину", categoryID: BuiltInCategory.groceries.id),
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 62_000), kind: .expense,
                date: now.addingTimeInterval(-900), authorID: sasha.id, payerID: sasha.id), title: "Кофе и прогулка", categoryID: BuiltInCategory.cafes.id)
        ]
        do {
            let snapshot = HouseholdSnapshot(period: try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow"),
                monthlyFreePlan: Money(minorUnits: 12_000_000), openingFunds: Money(minorUnits: 12_000_000),
                transactions: records.map(\.transaction))
            return BudgetSession(household: snapshot, records: records, members: [masha, sasha], demoDate: now)
        } catch {
            preconditionFailure("Invalid compile-time demo fixture: \(error)")
        }
    }
}
#endif
