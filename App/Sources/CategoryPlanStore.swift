import Foundation
import FolkiDuoCore

/// Planned monthly amounts per category that the person set or confirmed, kept on this device.
/// Analytics prefers them over the automatic hint.
enum CategoryPlanStore {
    private static func key(_ scope: BudgetScope) -> String { "FolkiCategoryPlan.\(scope.rawValue)" }

    static func amounts(_ scope: BudgetScope) -> [UUID: Money] {
        guard let data = UserDefaults.standard.data(forKey: key(scope)),
              let raw = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { id, units in UUID(uuidString: id).map { ($0, Money(minorUnits: units)) } })
    }

    static func save(_ amounts: [UUID: Money], scope: BudgetScope) {
        let raw = Dictionary(uniqueKeysWithValues: amounts.map { ($0.key.uuidString, $0.value.minorUnits) })
        UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: key(scope))
    }

    /// The person's own amount, else the automatic hint.
    static func hint(for id: UUID, scope: BudgetScope, plan: Money, history: [Money]) -> Money? {
        amounts(scope)[id] ?? CategoryGuide.recommended(categoryID: id, monthlyPlan: plan, previousMonths: history)
    }
}
