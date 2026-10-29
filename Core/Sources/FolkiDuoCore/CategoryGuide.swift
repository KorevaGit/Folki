import Foundation

/// Suggested monthly amounts per category. A hint for beginners, never a hard limit.
public enum CategoryGuide {
    /// Typical share of a monthly plan for each built-in category. Shares add up to 100%.
    public static func share(of category: BuiltInCategory) -> Double {
        switch category {
        case .housing: 0.30
        case .groceries: 0.15
        case .transport: 0.07
        case .health: 0.04
        case .connectivity: 0.03
        case .children: 0.06
        case .debt: 0.05
        case .cafes: 0.06
        case .entertainment: 0.04
        case .clothing: 0.04
        case .gifts: 0.03
        case .travel: 0.05
        case .beauty: 0.03
        case .other: 0.05
        }
    }

    /// With history: a tenth below the usual monthly spend, a gentle push. Without: the typical share of the plan.
    /// Rounded down to 100 units; nil when there is nothing to base it on.
    public static func recommended(categoryID: UUID, monthlyPlan: Money, previousMonths: [Money]) -> Money? {
        let spent = previousMonths.map(\.minorUnits).filter { $0 > 0 }
        let raw: Int64
        if !spent.isEmpty {
            raw = spent.reduce(0, +) / Int64(spent.count) * 9 / 10
        } else if let builtIn = BuiltInCategory.allCases.first(where: { $0.id == categoryID }), monthlyPlan.minorUnits > 0 {
            raw = Int64((Double(monthlyPlan.minorUnits) * share(of: builtIn)).rounded(.down))
        } else {
            return nil
        }
        let rounded = raw / 10_000 * 10_000
        return rounded > 0 ? Money(minorUnits: rounded) : nil
    }
}
