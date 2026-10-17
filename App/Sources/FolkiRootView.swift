import SwiftUI
import FolkiDuoCore

private enum FolkiTab: Hashable { case summary, budget }

struct FolkiRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var selection: FolkiTab = .summary

    var body: some View {
        TabView(selection: $selection) {
            Tab("Сводка", systemImage: "square.grid.2x2.fill", value: .summary) {
                FolkiSummaryView(personal: personal, family: family) { selection = .budget }
            }
            Tab("Бюджет", systemImage: "wallet.bifold", value: .budget) {
                BudgetRootView(personal: personal, family: family)
            }
        }
        .tint(.orange)
    }
}

private struct FolkiSummaryView: View {
    let personal: BudgetSession
    let family: BudgetSession
    let openBudget: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(family.referenceDate, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Избранное").font(.title2.bold())
                        Button(action: openBudget) { budgetFavorite }.buttonStyle(.plain)
                            .accessibilityHint("Открыть вкладку «Бюджет»")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Дальше в Folki").font(.title2.bold())
                        VStack(spacing: 0) {
                            plannedModule("Задачи", subtitle: "Общие дела и планы", symbol: "checklist", color: .teal)
                            Divider().padding(.leading, 48)
                            plannedModule("Продуктовая корзина", subtitle: "Покупки для дома", symbol: "basket.fill", color: .green)
                        }.budgetCard()
                        Text("Будущие разделы появятся рядом с бюджетом. Здесь соберём главное из каждого.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20).padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Сводка")
        }
    }

    private var budgetFavorite: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Бюджет", systemImage: "wallet.bifold.fill").foregroundStyle(.orange)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }.font(.headline)
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Личный · сегодня").font(.subheadline).foregroundStyle(.secondary)
                    Text(personal.result.map { MoneyText.string($0.todayRemaining) } ?? "—")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    HStack(spacing: 4) {
                        Text("Общий").foregroundStyle(.secondary)
                        Text(family.result.map { MoneyText.string($0.todayRemaining) } ?? "—").fontWeight(.semibold)
                    }.font(.subheadline)
                }
                Spacer(minLength: 0)
                FinancialRings(personal: personal.result, family: family.result, compact: true)
                    .frame(width: 94, height: 94).accessibilityHidden(true)
            }
            Divider()
            Text(personal.result == nil ? "Настройте личный бюджет — семейные записи останутся отдельно." : "Личные и семейные деньги учитываются отдельно.")
                .font(.footnote).foregroundStyle(.secondary)
        }.budgetCard()
    }

    private func plannedModule(_ title: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("В планах").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 10)
    }
}
