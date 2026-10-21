import Foundation
import Testing
import FolkiDuoCore

struct StarterAllocationTests {
    private func rub(_ value: Int64) -> Money { Money(minorUnits: value * 100) }
    @Test func oneActionProducesAConservedPlanWithDailyMoney() throws {
        let housing = UUID(), phone = UUID(), reserve = UUID()
        let plan = try StarterAllocation.suggested(income: rub(100_000), days: 30, percentages: [housing: 30, phone: 3, reserve: 20])
        #expect(plan.amounts == [housing: rub(30_000), phone: rub(3_000), reserve: rub(20_000)])
        #expect(plan.living == rub(47_000))
        #expect(plan.daily.minorUnits == 156_667)
        #expect(plan.living.minorUnits + plan.amounts.values.reduce(0) { $0 + $1.minorUnits } == plan.income.minorUnits)
    }
    @Test func editingOneEnvelopeKeepsOthersAndProtectsADay() throws {
        let first = UUID(), second = UUID()
        let initial = try StarterAllocation.suggested(income: rub(10_000), days: 10, percentages: [first: 30, second: 20])
        let changed = try initial.adjusting(first, to: rub(100_000))
        #expect(changed.amounts[second] == initial.amounts[second])
        #expect(changed.amounts[first] == rub(7_000))
        #expect(changed.living == rub(1_000))
        #expect(try changed.adjusting(first, to: rub(1_000)).living == rub(7_000))
        #expect(throws: BudgetError.missingReserve) { try initial.adjusting(UUID(), to: rub(1)) }
    }
    @Test func smallAndLastDayPlansNeverOverAllocate() throws {
        let first = UUID(), second = UUID()
        let last = try StarterAllocation.suggested(income: rub(500), days: 1, percentages: [first: 30, second: 20])
        #expect(last.living == rub(500))
        #expect(last.amounts.values.allSatisfy { $0.minorUnits == 0 })
        let small = try StarterAllocation.suggested(income: Money(minorUnits: 7), days: 3, percentages: [first: 60, second: 30])
        #expect(small.living.minorUnits >= small.minimumLiving.minorUnits)
        #expect(small.living.minorUnits + small.amounts.values.reduce(0) { $0 + $1.minorUnits } == 7)
    }
    @Test func largeValuesAndInvalidInputAreChecked() throws {
        let id = UUID()
        let large = try StarterAllocation.suggested(income: Money(minorUnits: Int64.max), days: 30, percentages: [id: 90])
        #expect(large.living.minorUnits >= large.minimumLiving.minorUnits)
        #expect(throws: BudgetError.invalidAmount) { try StarterAllocation.suggested(income: rub(0), days: 30, percentages: [id: 30]) }
        #expect(throws: BudgetError.invalidAmount) { try StarterAllocation.suggested(income: rub(1_000), days: 0, percentages: [id: 30]) }
        #expect(throws: BudgetError.invalidPlan) { try StarterAllocation.suggested(income: rub(1_000), days: 30, percentages: [id: 100, UUID(): 30]) }
        #expect(throws: BudgetError.insufficientReserve) { try StarterAllocation(income: rub(1_000), days: 30, amounts: [id: rub(1_000)]) }
    }
}
