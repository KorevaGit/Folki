/// A monthly plan can use existing unreserved cash once, without treating it as recurring income.
/// All amounts are minor units in the same currency.
public struct PlanCapacity: Equatable, Sendable {
    public let income: Int64
    public let reserved: Int64
    public let minimumLiving: Int64
    public let monthlyShortfall: Int64
    public let balanceUsed: Int64
    public let shortfall: Int64
    public let living: Int64
    public let recommendedIncome: Int64?

    public init(income: Int64, reserved: Int64, days: Int, availableBalance: Int64 = 0, usesBalance: Bool = false) {
        let income = max(0, income), reserved = max(0, reserved)
        let days = Int64(max(2, days))
        self.income = income
        self.reserved = reserved
        // Keep at least one day's share for living, rounded up to the minor unit.
        let minimum = max(1, income / days + (income % days == 0 ? 0 : 1))
        minimumLiving = minimum
        let spare = max(0, income - reserved)
        // The difference cannot exceed Int64.max: minimum <= income for positive income.
        let gap = reserved > income ? reserved - income : 0
        let deficit = gap.addingReportingOverflow(minimum)
        let needed = reserved > income ? (deficit.overflow ? Int64.max : deficit.partialValue) : max(0, minimum - spare)
        monthlyShortfall = needed
        balanceUsed = usesBalance ? min(max(0, availableBalance), needed) : 0
        shortfall = needed - balanceUsed
        living = reserved > income ? max(0, balanceUsed - (reserved - income)) : spare + balanceUsed

        // Find the smallest recurring income that covers the plan after the chosen one-off cash.
        // Binary search avoids multiplying large monetary amounts by a day count.
        let netReserved = max(0, reserved - balanceUsed)
        func fits(_ value: Int64) -> Bool {
            let floor = max(1, value / days + (value % days == 0 ? 0 : 1))
            return value >= floor && value - floor >= netReserved
        }
        if fits(Int64.max) {
            var low = income, high = Int64.max
            while low < high {
                let middle = low + (high - low) / 2
                if fits(middle) { high = middle } else { low = middle + 1 }
            }
            // Whole currency units make the proposed income easy to read and enter.
            let rounded = low.addingReportingOverflow((100 - low % 100) % 100)
            recommendedIncome = rounded.overflow ? low : rounded.partialValue
        } else {
            recommendedIncome = nil
        }
    }
}
