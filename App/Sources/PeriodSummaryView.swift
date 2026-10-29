import SwiftUI
import FolkiDuoCore

/// "Итоги периода": opened from the banner after a period was extended. Nothing to decide here,
/// the leftover or the overspend is already carried into the new period.
struct PeriodSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    let period: BudgetPeriod
    /// Opens "Внести" after this sheet closes.
    let addMoney: () -> Void

    private var lastDay: Date { period.endExclusive.addingTimeInterval(-1) }
    private var closing: DailyBudgetSnapshot? { session.overview(on: lastDay).result }
    private var analytics: BudgetAnalyticsSnapshot? { try? session.analytics(.month, on: period.start) }
    private var range: String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = session.calendar.timeZone
        return period.start.formatted(style) + " — " + lastDay.formatted(style)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FolkiSpacing.section) {
                    if let closing {
                        let left = closing.monthlyRemaining
                        VStack(spacing: FolkiSpacing.xs) {
                            Text(left.minorUnits >= 0 ? "Осталось" : "Сверх плана").font(FolkiFont.headline).foregroundStyle(Color.folkiSecondary)
                            Text(MoneyText.whole(left.minorUnits >= 0 ? left : Money(minorUnits: -left.minorUnits).roundedUpToWholeUnits))
                                .font(FolkiFont.moneyLarge).monospacedDigit()
                                .foregroundStyle(left.minorUnits >= 0 ? Color.folkiAccent : Color.folkiOver)
                            Text(left.minorUnits >= 0 ? "Остаток уже перенесён в новый период"
                                 : "Перерасход уже учтён: новый период начат с минусом")
                                .folkiText(.caption).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, FolkiSpacing.page)
                    }
                    if let analytics {
                        VStack(spacing: FolkiSpacing.item) {
                            stat(String(localized: "Потрачено"), MoneyText.whole((try? analytics.netSpending) ?? analytics.expenses))
                            if let plan = closing?.periodPlan, plan.minorUnits > 0 {
                                stat(String(localized: "План периода"), MoneyText.whole(plan))
                            }
                            if let top = analytics.categories.first(where: { $0.expenses.minorUnits > 0 }) {
                                stat(String(localized: "Больше всего"), session.catalog.category(for: top.categoryID).name)
                            }
                            stat(String(localized: "Записей"), "\(analytics.recordCount)")
                        }.budgetCard()
                    }
                    VStack(spacing: FolkiSpacing.item) {
                        Button("Внести деньги") { dismiss(); addMoney() }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                        Button("Готово") { dismiss() }.frame(minHeight: 44)
                    }
                }.folkiPagePadding()
            }
            .background { FolkiBackground() }
            .navigationTitle("Итоги \(range)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { FolkiCloseButton { dismiss() } } }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).font(FolkiFont.moneyRow).monospacedDigit()
        }.font(FolkiFont.caption)
    }
}
