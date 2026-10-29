import Foundation
import Testing
import CoreData
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor struct CategoryRepositoryTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T09:00:00Z")!
    private func rub(_ n: Int64) -> Money { Money(minorUnits: n * 100) }
    private func path() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("FolkiCategories-\(UUID())") }
    private func budget(_ repo: BudgetRepository, _ scope: BudgetScope) throws -> StoredBudget {
        try #require(try repo.load(asOf: now, scope: scope))
    }
    private func open(_ directory: URL, author: UUID) async throws -> BudgetRepository {
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: author)
        if try repo.load(asOf: now, scope: .personal) == nil {
            for scope in BudgetScope.allCases {
                try repo.createPlan(monthlyPlan: rub(10000), available: rub(10000), asOf: now, timeZone: "Europe/Moscow", scope: scope)
            }
        }
        return repo
    }
    private func expense(_ budget: StoredBudget, author: UUID, category: UUID, id: UUID = UUID()) -> LedgerRecord {
        LedgerRecord(transaction: TransactionSnapshot(id: id, amount: rub(100), kind: .expense, date: now,
            authorID: author, payerID: author), title: "Покупка", categoryID: category)
    }

    @Test func customCategoriesAreScopedToTheirBudgetAndSurviveReopen() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID(), repo = try await open(directory, author: author)
        let mine = try repo.createCategory(name: "Хобби", symbol: "paintpalette.fill", color: .purple, isEssential: false,
                                           in: budget(repo, .personal), asOf: now)
        let ours = try repo.createCategory(name: "Питомцы", symbol: "pawprint.fill", color: .brown, isEssential: true,
                                           in: budget(repo, .family), asOf: now)
        try repo.close()

        let reopened = try await BudgetRepository.open(directory: directory, localMemberID: author)
        #expect(try reopened.categories(scope: .personal).map(\.id) == [mine])
        #expect(try reopened.categories(scope: .family).map(\.id) == [ours])
        let pets = try #require(try reopened.categories(scope: .family).first)
        #expect(pets.name == "Питомцы" && pets.symbol == "pawprint.fill" && pets.color == .brown && pets.isEssential)
        // A personal category cannot be used in the family budget, and the other way round.
        #expect(throws: LedgerError.missingCategory) {
            try reopened.save(expense(budget(reopened, .family), author: author, category: mine),
                              in: budget(reopened, .family), expectedRevision: nil, asOf: now)
        }
        try reopened.save(expense(budget(reopened, .family), author: author, category: ours),
                          in: budget(reopened, .family), expectedRevision: nil, asOf: now)
        #expect(try reopened.history(scope: .family).first?.categoryID == ours)
        try reopened.close()
    }

    @Test func familyGraphReachesFamilyCategoriesOnly() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await open(directory, author: UUID())
        let mine = try repo.createCategory(name: "Хобби", symbol: "paintpalette.fill", color: .purple, isEssential: false,
                                           in: budget(repo, .personal), asOf: now)
        let ours = try repo.createCategory(name: "Питомцы", symbol: "pawprint.fill", color: .brown, isEssential: true,
                                           in: budget(repo, .family), asOf: now)
        let root = try repo.container.viewContext.existingObject(with: repo.sharingRootID(householdID: budget(repo, .family).snapshot.id))
        let reachable = (root.value(forKey: "categories") as? Set<NSManagedObject> ?? []).compactMap { $0.value(forKey: "id") as? UUID }
        #expect(reachable == [ours])
        #expect(!reachable.contains(mine))
        try repo.close()
    }

    @Test func namesMustBeValidAndUniqueAmongActiveCategories() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await open(directory, author: UUID())
        let personal = try budget(repo, .personal)
        #expect(throws: LedgerError.invalidCategory) {
            try repo.createCategory(name: "  ", symbol: "tag.fill", color: .gray, isEssential: false, in: personal, asOf: now)
        }
        #expect(throws: LedgerError.duplicateCategory) {
            try repo.createCategory(name: "продукты", symbol: "tag.fill", color: .gray, isEssential: true, in: personal, asOf: now)
        }
        try repo.createCategory(name: "Хобби", symbol: "paintpalette.fill", color: .purple, isEssential: false, in: personal, asOf: now)
        #expect(throws: LedgerError.duplicateCategory) {
            try repo.createCategory(name: " ХОББИ ", symbol: "tag.fill", color: .gray, isEssential: false, in: personal, asOf: now)
        }
        // The same name is fine in the other budget.
        try repo.createCategory(name: "Хобби", symbol: "paintpalette.fill", color: .purple, isEssential: false,
                                in: budget(repo, .family), asOf: now)
        #expect(try repo.categories(scope: .personal).count == 1)
        try repo.close()
    }

    @Test func archivedCategoryStaysOnOldRecordsButCannotBePickedAgain() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID(), repo = try await open(directory, author: author)
        let id = try repo.createCategory(name: "Секция", symbol: "figure.run", color: .indigo, isEssential: false,
                                         in: budget(repo, .personal), asOf: now)
        let recordID = UUID()
        try repo.save(expense(budget(repo, .personal), author: author, category: id, id: recordID),
                      in: budget(repo, .personal), expectedRevision: nil, asOf: now)
        let category = try #require(try repo.categories(scope: .personal).first)
        try repo.setCategoryArchived(category, archived: true, in: budget(repo, .personal), asOf: now)
        #expect(throws: LedgerError.conflict) {
            try repo.setCategoryArchived(category, archived: true, in: budget(repo, .personal), asOf: now)
        }
        #expect(try repo.catalog(scope: .personal).selectable.contains { $0.id == id } == false)
        #expect(try repo.catalog(scope: .personal).category(for: id).name == "Секция")

        #expect(throws: LedgerError.missingCategory) {
            try repo.save(expense(budget(repo, .personal), author: author, category: id),
                          in: budget(repo, .personal), expectedRevision: nil, asOf: now)
        }
        // Editing the old record keeps its archived category.
        let old = try #require(try budget(repo, .personal).records.first { $0.id == recordID })
        let edited = LedgerRecord(transaction: TransactionSnapshot(id: recordID, amount: rub(150), kind: .expense, date: now,
            authorID: author, payerID: author), title: "Секция за месяц", categoryID: id)
        try repo.save(edited, in: budget(repo, .personal), expectedRevision: old.revision, asOf: now)
        #expect(try budget(repo, .personal).records.first?.categoryID == id)

        // A new category can take the archived name; restoring the old one then clashes.
        try repo.createCategory(name: "Секция", symbol: "figure.run", color: .blue, isEssential: false,
                                in: budget(repo, .personal), asOf: now)
        let archived = try #require(try repo.categories(scope: .personal).first { $0.id == id })
        #expect(throws: LedgerError.duplicateCategory) {
            try repo.setCategoryArchived(archived, archived: false, in: budget(repo, .personal), asOf: now)
        }
        try repo.close()
    }

    @Test func editingRequiresTheCurrentRevision() async throws {
        let directory = path(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await open(directory, author: UUID())
        try repo.createCategory(name: "Хобби", symbol: "paintpalette.fill", color: .purple, isEssential: false,
                                in: budget(repo, .personal), asOf: now)
        let stale = try #require(try repo.categories(scope: .personal).first)
        try repo.updateCategory(stale, name: "Творчество", symbol: "paintbrush.fill", color: .pink, isEssential: false,
                                in: budget(repo, .personal), asOf: now)
        #expect(throws: LedgerError.conflict) {
            try repo.updateCategory(stale, name: "Другое имя", symbol: "tag.fill", color: .gray, isEssential: true,
                                    in: budget(repo, .personal), asOf: now)
        }
        let current = try #require(try repo.categories(scope: .personal).first)
        #expect(current.name == "Творчество" && current.color == .pink)
        #expect(throws: LedgerError.missingRecord) {
            try repo.setCategoryArchived(BuiltInCategory.groceries.category, archived: true, in: budget(repo, .personal), asOf: now)
        }
        try repo.close()
    }
}
