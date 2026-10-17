#if FOLKI_DEMO
import Foundation
import FolkiDuoCore

/// Excluded by conditional compilation from Debug/Release product code.
enum DemoFixtures {
    @MainActor static func makeSession() -> BudgetSession {
        let masha = Member(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Маша")
        let sasha = Member(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Саша")
        let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
        let previous = ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!
        let records = [
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 7_845_000), kind: .expense,
                date: previous, authorID: masha.id, payerID: masha.id), title: "Расходы ранее в октябре", symbol: "calendar"),
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 105_000), kind: .expense,
                date: now.addingTimeInterval(-1800), authorID: masha.id, payerID: masha.id), title: "Продукты к ужину", symbol: "basket.fill"),
            LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 62_000), kind: .expense,
                date: now.addingTimeInterval(-900), authorID: sasha.id, payerID: sasha.id), title: "Кофе и прогулка", symbol: "cup.and.saucer.fill")
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
