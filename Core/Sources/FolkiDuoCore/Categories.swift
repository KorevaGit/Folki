import Foundation

/// Category colors. Red, apricot and sage are left out on purpose: red means overspending,
/// apricot and sage are the personal and family rings.
public enum CategoryColor: String, CaseIterable, Identifiable, Sendable {
    case blue, sky, cyan, indigo, purple, lavender, pink, plum, brown, slate, gray
    public var id: String { rawValue }
}

/// A spending category. Built-in ones live in code with fixed identifiers, so two devices
/// never create duplicates and their names can be localized. Custom ones belong to one budget.
public struct SpendingCategory: Identifiable, Hashable, Sendable {
    public static let maxNameLength = 40

    public let id: UUID
    public let name: String
    public let symbol: String
    public let color: CategoryColor
    /// Needs versus wants, as in the 50/30/20 rule.
    public let isEssential: Bool
    public let isArchived: Bool
    public let isBuiltIn: Bool
    public let revision: UUID?

    public init(id: UUID, name: String, symbol: String, color: CategoryColor, isEssential: Bool,
                isArchived: Bool = false, isBuiltIn: Bool = false, revision: UUID? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.color = color
        self.isEssential = isEssential; self.isArchived = isArchived; self.isBuiltIn = isBuiltIn; self.revision = revision
    }

    /// Trims a user-entered name; nil when it is empty or too long.
    public static func validName(_ name: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= maxNameLength else { return nil }
        return clean
    }
}

public enum BuiltInCategory: Int, CaseIterable, Sendable {
    case housing = 1, groceries, transport, health, connectivity, children, debt
    case cafes, entertainment, clothing, gifts, travel, beauty, other

    public var id: UUID { UUID(uuidString: String(format: "F01C0000-0000-4000-8000-%012d", rawValue))! }

    public var category: SpendingCategory {
        SpendingCategory(id: id, name: name, symbol: symbol, color: color, isEssential: isEssential, isBuiltIn: true)
    }

    public static var all: [SpendingCategory] { allCases.map(\.category) }

    public static func named(_ id: UUID) -> BuiltInCategory? { allCases.first { $0.id == id } }

    /// What a new budget starts with; the rest of the built-ins are added from a list.
    public static let defaultEnabled: Set<BuiltInCategory> = [.housing, .groceries, .cafes, .transport, .health,
                                                                  .children, .clothing, .connectivity, .other]

    /// The Russian name; it is also the key in the String Catalog.
    public var sourceName: String {
        switch self {
        case .housing: "Жильё и коммуналка"
        case .groceries: "Продукты"
        case .transport: "Транспорт"
        case .health: "Здоровье"
        case .connectivity: "Связь и подписки"
        case .children: "Дети"
        case .debt: "Кредиты и долги"
        case .cafes: "Кафе и рестораны"
        case .entertainment: "Развлечения"
        case .clothing: "Одежда"
        case .gifts: "Подарки"
        case .travel: "Путешествия"
        case .beauty: "Красота и уход"
        case .other: "Другое"
        }
    }

    /// The name in the user's language.
    var name: String { Bundle.module.localizedString(forKey: sourceName, value: nil, table: nil) }

    var symbol: String {
        switch self {
        case .housing: "house.fill"
        case .groceries: "cart.fill"
        case .transport: "bus.fill"
        case .health: "cross.case.fill"
        case .connectivity: "wifi"
        case .children: "figure.and.child.holdinghands"
        case .debt: "creditcard.fill"
        case .cafes: "fork.knife"
        case .entertainment: "theatermasks.fill"
        case .clothing: "tshirt.fill"
        case .gifts: "gift.fill"
        case .travel: "airplane"
        case .beauty: "sparkles"
        case .other: "ellipsis"
        }
    }

    var color: CategoryColor {
        switch self {
        case .housing: .brown
        case .groceries: .blue
        case .transport: .indigo
        case .health: .cyan
        case .connectivity: .sky
        case .children: .lavender
        case .debt: .slate
        case .cafes: .plum
        case .entertainment: .purple
        case .clothing: .pink
        case .gifts: .pink
        case .travel: .sky
        case .beauty: .lavender
        case .other: .gray
        }
    }

    var isEssential: Bool {
        switch self {
        case .housing, .groceries, .transport, .health, .connectivity, .children, .debt: true
        case .cafes, .entertainment, .clothing, .gifts, .travel, .beauty, .other: false
        }
    }
}

/// Resolves the category of a record. An unknown identifier — a custom category that has not
/// synced yet — falls back to «Другое» rather than failing.
public struct CategoryCatalog: Sendable {
    public let all: [SpendingCategory]
    private let byID: [UUID: SpendingCategory]

    /// Built-ins switched on in this budget; a stored row with a built-in's id switches it on or off.
    public let enabledBuiltIns: [BuiltInCategory]

    /// `custom` may hold rows whose id is a built-in's: those only say whether that built-in is used.
    public init(custom: [SpendingCategory] = []) {
        let overrides = Dictionary(custom.compactMap { row in BuiltInCategory.named(row.id).map { ($0, !row.isArchived) } },
                                   uniquingKeysWith: { first, _ in first })
        enabledBuiltIns = BuiltInCategory.allCases.filter { overrides[$0] ?? BuiltInCategory.defaultEnabled.contains($0) }
        all = BuiltInCategory.all + custom.filter { BuiltInCategory.named($0.id) == nil }
        byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Built-ins that are not used yet and can be added.
    public var availableBuiltIns: [BuiltInCategory] { BuiltInCategory.allCases.filter { !enabledBuiltIns.contains($0) } }

    /// Categories a new record can use: enabled built-ins first, then custom ones by name.
    public var selectable: [SpendingCategory] {
        enabledBuiltIns.map(\.category) + all.filter { !$0.isBuiltIn && !$0.isArchived }.sorted { $0.name < $1.name }
    }

    public func category(for id: UUID) -> SpendingCategory {
        byID[id] ?? BuiltInCategory.other.category
    }

    public func contains(_ id: UUID) -> Bool { byID[id] != nil }
}
