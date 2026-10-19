import SwiftUI
import FolkiDuoCore

/// Plain-language findings for one analytics period: small purchases, days without spending, and one tip.
@MainActor struct PeriodInsights {
    /// Purchases at or under this amount count as small (500 ₽).
    static let smallLimit: Int64 = 50_000

    let smallCount: Int
    let smallTotal: Money
    let smallTopCategory: SpendingCategory?
    let noSpendDays: Int
    let observedDays: Int
    let tip: String?

    init(result: BudgetAnalyticsSnapshot, records: [LedgerRecord], catalog: CategoryCatalog,
         snapshot: DailyBudgetSnapshot?, isMonth: Bool) {
        let expenses = records.filter {
            $0.transaction.kind == .expense && !$0.transaction.isDeleted
                && $0.transaction.date >= result.interval.start && $0.transaction.date <= result.cutoff
        }
        let small = expenses.filter { $0.transaction.amount.minorUnits <= Self.smallLimit }
        smallCount = small.count
        smallTotal = Money(minorUnits: small.reduce(0) { $0 + $1.transaction.amount.minorUnits })
        let byCategory = Dictionary(grouping: small, by: \.categoryID)
        smallTopCategory = byCategory.max { $0.value.count < $1.value.count }.map { catalog.category(for: $0.key) }

        let observed = result.buckets.filter(\.isObserved)
        observedDays = observed.count
        noSpendDays = observed.filter { $0.expenses.minorUnits == 0 }.count

        tip = Self.makeTip(result: result, catalog: catalog, snapshot: snapshot, isMonth: isMonth,
                           smallCount: small.count, smallTotal: smallTotal, noSpendDays: noSpendDays)
    }

    private static func makeTip(result: BudgetAnalyticsSnapshot, catalog: CategoryCatalog, snapshot: DailyBudgetSnapshot?,
                                isMonth: Bool, smallCount: Int, smallTotal: Money, noSpendDays: Int) -> String? {
        let total = max(0, (try? result.netSpending.minorUnits) ?? result.expenses.minorUnits)
        guard total > 0 else { return nil }
        // The biggest "want" with a real share is the most useful lever.
        let wants = result.categories
            .map { (catalog.category(for: $0.categoryID), $0.expenses.minorUnits - $0.refunds.minorUnits) }
            .filter { !$0.0.isEssential && $0.0.id != BuiltInCategory.other.id && $0.1 * 5 >= total }
            .max { $0.1 < $1.1 }
        if let (category, amount) = wants {
            let quarter = amount / 4
            if isMonth, let days = snapshot?.futureAllocation?.days, days > 0, quarter / Int64(days) >= 5_000 {
                let perDay = Money(minorUnits: quarter / Int64(days) / 1_000 * 1_000)
                return "Больше всего из желаний — «\(category.name)»: \(MoneyText.whole(Money(minorUnits: amount).roundedDownToWholeUnits)). Если тратить на четверть меньше, до конца месяца будет на \(MoneyText.whole(perDay)) в день больше."
            }
            return "Больше всего из желаний — «\(category.name)»: \(MoneyText.whole(Money(minorUnits: amount).roundedDownToWholeUnits)). Это первое место, где можно сэкономить без потерь."
        }
        if smallCount >= 8 {
            return "\(smallCount) мелких покупок дали \(MoneyText.whole(smallTotal.roundedDownToWholeUnits)). Мелочи заметнее всего складываются."
        }
        if noSpendDays >= 3 {
            return "\(noSpendDays) дн. без трат — отличная привычка."
        }
        return nil
    }
}

/// One sentence on top of analytics.
struct InsightTip: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill").font(.title3).foregroundStyle(Color.budget(.personal))
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .budgetCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Подсказка. \(text)")
    }
}

/// Small purchases and days without spending, side by side.
struct HabitsCard: View {
    let insights: PeriodInsights
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tile(title: "Мелкие покупки", symbol: "cup.and.saucer.fill",
                 value: MoneyText.whole(insights.smallTotal.roundedDownToWholeUnits),
                 caption: insights.smallCount == 0 ? "до 500 ₽ — не было"
                    : "\(insights.smallCount) шт. до 500 ₽" + (insights.smallTopCategory.map { ", чаще «\($0.name)»" } ?? ""))
            tile(title: "Без трат", symbol: "leaf.fill",
                 value: "\(insights.noSpendDays) дн.",
                 caption: "из \(insights.observedDays)")
        }
    }
    private func tile(title: String, symbol: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(Color.folkiAccent)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .budgetCard()
        .accessibilityElement(children: .combine)
    }
}
