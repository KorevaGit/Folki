import Foundation
import Testing
@testable import FolkiDuoCore

struct CategoryTests {
    private let author = UUID()
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/Moscow")!; return value
    }
    private func record(_ rubles: Int64, kind: TransactionKind = .expense, category: UUID) -> LedgerRecord {
        LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: rubles * 100), kind: kind, date: now,
            authorID: author, payerID: author), title: "Запись", categoryID: category)
    }

    @Test func builtInSetIsStableUniqueAndSplitIntoNeedsAndWants() {
        let all = BuiltInCategory.all
        #expect(all.count == 14)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.name)).count == all.count)
        #expect(all.filter(\.isEssential).count == 7)
        #expect(BuiltInCategory.groceries.id.uuidString == "F01C0000-0000-4000-8000-000000000002")
        #expect(all.allSatisfy { $0.isBuiltIn && !$0.isArchived })
    }

    @Test func catalogHidesArchivedFromSelectionButStillResolvesThem() {
        let archived = SpendingCategory(id: UUID(), name: "Секция", symbol: "figure.run", color: .indigo, isEssential: false, isArchived: true)
        let active = SpendingCategory(id: UUID(), name: "Аптека", symbol: "pills.fill", color: .cyan, isEssential: true)
        let catalog = CategoryCatalog(custom: [archived, active])
        #expect(catalog.selectable.contains(active))
        #expect(!catalog.selectable.contains(archived))
        #expect(catalog.category(for: archived.id) == archived)
        #expect(catalog.category(for: UUID()).id == BuiltInCategory.other.id)
    }

    @Test func validNameTrimsAndRejectsEmptyOrLong() {
        #expect(SpendingCategory.validName("  Аптека ") == "Аптека")
        #expect(SpendingCategory.validName("   ") == nil)
        #expect(SpendingCategory.validName(String(repeating: "я", count: SpendingCategory.maxNameLength + 1)) == nil)
    }

    @Test func analyticsSplitsNetSpendingIntoEssentialAndWants() throws {
        let pharmacy = SpendingCategory(id: UUID(), name: "Аптека", symbol: "pills.fill", color: .cyan, isEssential: true)
        let records = [
            record(1000, category: BuiltInCategory.groceries.id),
            record(300, kind: .refund, category: BuiltInCategory.groceries.id),
            record(500, category: BuiltInCategory.cafes.id),
            record(200, category: pharmacy.id),
            record(100, category: UUID())
        ]
        let result = try BudgetAnalytics.calculate(records: records, period: .day, anchor: now, asOf: now,
            calendar: calendar, catalog: CategoryCatalog(custom: [pharmacy]))
        #expect(result.essentialSpending == Money(minorUnits: 90000))
        #expect(result.wantsSpending == Money(minorUnits: 60000))
        // The unsynced category is folded into «Другое» instead of becoming its own row.
        #expect(Set(result.categories.map(\.categoryID)) == [BuiltInCategory.groceries.id, BuiltInCategory.cafes.id,
                                                             pharmacy.id, BuiltInCategory.other.id])
    }

    @Test func descriptionIsOptional() throws {
        let period = try BudgetPeriod(monthContaining: now, timeZoneIdentifier: "Europe/Moscow")
        let budget = StoredBudget(snapshot: HouseholdSnapshot(period: period, monthlyFreePlan: Money(minorUnits: 100_000),
            openingFunds: Money(minorUnits: 100_000)), periodID: UUID(), members: [Member(id: author, name: "Я")], records: [])
        let untitled = LedgerRecord(transaction: TransactionSnapshot(amount: Money(minorUnits: 500), kind: .expense, date: now,
            authorID: author, payerID: author), title: "", categoryID: BuiltInCategory.cafes.id)
        #expect(try LedgerRules.replacing(untitled, in: budget, asOf: now).records.count == 1)
    }
}
