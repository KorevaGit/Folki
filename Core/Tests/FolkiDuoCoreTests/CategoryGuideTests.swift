import Testing
import Foundation
@testable import FolkiDuoCore

struct CategoryGuideTests {
    @Test func sharesAddUpToWholePlan() {
        let total = BuiltInCategory.allCases.reduce(0) { $0 + CategoryGuide.share(of: $1) }
        #expect(abs(total - 1) < 0.0001)
    }

    @Test func withoutHistoryUsesShareOfPlan() {
        let plan = Money(minorUnits: 6_000_000) // 60 000 ₽
        let groceries = CategoryGuide.recommended(categoryID: BuiltInCategory.groceries.id, monthlyPlan: plan, previousMonths: [])
        #expect(groceries == Money(minorUnits: 900_000)) // 15% → 9 000 ₽
    }

    @Test func withHistoryNudgesBelowAverageAndRounds() {
        let history = [Money(minorUnits: 1_000_000), Money(minorUnits: 1_234_500), Money(minorUnits: 0)]
        let value = CategoryGuide.recommended(categoryID: BuiltInCategory.cafes.id, monthlyPlan: Money(minorUnits: 0), previousMonths: history)
        // Average of non-zero months 11 172,50 ₽, minus a tenth 10 055,25 ₽, down to 100 ₽ → 10 000 ₽.
        #expect(value == Money(minorUnits: 1_000_000))
    }

    @Test func customCategoryWithoutHistoryHasNoHint() {
        #expect(CategoryGuide.recommended(categoryID: UUID(), monthlyPlan: Money(minorUnits: 6_000_000), previousMonths: []) == nil)
    }
}
