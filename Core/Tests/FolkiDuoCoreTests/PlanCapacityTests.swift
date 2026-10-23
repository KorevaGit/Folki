import Testing
import FolkiDuoCore

struct PlanCapacityTests {
    @Test func recommendsEnoughIncomeToUnblockThePlan() {
        let plan = PlanCapacity(income: 5_000_000, reserved: 6_000_000, days: 30)
        #expect(plan.monthlyShortfall == 1_166_667)
        #expect(plan.shortfall == plan.monthlyShortfall)
        let recommended = plan.recommendedIncome!
        #expect(recommended == 6_206_900)
        #expect(PlanCapacity(income: recommended, reserved: 6_000_000, days: 30).shortfall == 0)
    }

    @Test func cashCoversOnlyTheGapWithoutChangingMonthlyIncome() {
        let plan = PlanCapacity(income: 5_000_000, reserved: 6_000_000, days: 30,
                                availableBalance: 4_000_000, usesBalance: true)
        #expect(plan.income == 5_000_000)
        #expect(plan.balanceUsed == 1_166_667)
        #expect(plan.shortfall == 0)
        #expect(plan.living == plan.minimumLiving)
        #expect(plan.monthlyShortfall > 0)
    }

    @Test func partialCashStillOffersAnIncomeThatCoversTheRemainder() {
        let plan = PlanCapacity(income: 5_000_000, reserved: 6_000_000, days: 30,
                                availableBalance: 500_000, usesBalance: true)
        #expect(plan.shortfall == 666_667)
        let recommended = plan.recommendedIncome!
        #expect(PlanCapacity(income: recommended, reserved: 6_000_000, days: 30,
                             availableBalance: 500_000, usesBalance: true).shortfall == 0)
    }

    @Test func existingCashRequiresExplicitSelection() {
        let plan = PlanCapacity(income: 5_000_000, reserved: 6_000_000, days: 30, availableBalance: 4_000_000)
        #expect(plan.balanceUsed == 0)
        #expect(plan.shortfall > 0)
        let affordable = PlanCapacity(income: 5_000_000, reserved: 2_000_000, days: 30,
                                      availableBalance: 4_000_000, usesBalance: true)
        #expect(affordable.balanceUsed == 0)
        #expect(affordable.living == 3_000_000)
    }

    @Test func boundaryValuesDoNotOverflowOrSuggestAnImpossibleIncome() {
        let large = PlanCapacity(income: 1, reserved: .max, days: 30, availableBalance: .max, usesBalance: true)
        #expect(large.shortfall == 0)
        #expect(large.living == 1)
        #expect(PlanCapacity(income: 1, reserved: .max, days: 30).recommendedIncome == nil)
        #expect(PlanCapacity(income: .max, reserved: 0, days: 30).living == Int64.max)
        #expect(PlanCapacity(income: 0, reserved: 0, days: 0).shortfall == 1)
        #expect(PlanCapacity(income: 0, reserved: .max, days: 30).recommendedIncome == nil)
    }
}
