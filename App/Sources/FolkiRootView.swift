import SwiftUI
import FolkiDuoCore

private enum FolkiTab: Hashable { case summary, budget }

struct FolkiRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var selection: FolkiTab = .summary
    @State private var selectedDay: Date?

    var body: some View {
        TabView(selection: $selection) {
            Tab("Сводка", systemImage: "square.grid.2x2.fill", value: .summary) {
                FolkiSummaryView(personal: personal, family: family, selectedDay: $selectedDay) { selection = .budget }
            }
            Tab("Бюджет", systemImage: "wallet.bifold", value: .budget) {
                BudgetRootView(personal: personal, family: family, selectedDay: $selectedDay)
            }
        }
        .tint(Color.folkiAccent)
    }
}

private struct FolkiSummaryView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @Binding var selectedDay: Date?
    let openBudget: () -> Void
    @State private var showingFamily = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let date = selectedDay ?? family.referenceDate
        let personalDay = personal.overview(on: date)
        let familyDay = family.overview(on: date)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    BudgetWeekCalendar(selection: $selectedDay, today: family.referenceDate, calendar: family.calendar)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Избранное").font(.title2.bold())
                        Button(action: openBudget) { budgetFavorite(personal: personalDay.result, family: familyDay.result) }.buttonStyle(.plain)
                            .accessibilityHint("Открыть вкладку «Бюджет»")
                    }
                    SummaryPlanningSection(personal: personal, family: family)
                    SpendingReviewCard(session: personal, date: date)
                    SpendingReviewCard(session: family, date: date)
                    familyInvitation
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
        .sheet(isPresented: $showingFamily) { SharingView(session: family) }
    }

    private func budgetFavorite(personal: DailyBudgetSnapshot?, family: DailyBudgetSnapshot?) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(spacing: 18))
        let familyLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Бюджет", systemImage: "wallet.bifold.fill").foregroundStyle(Color.folkiAccent)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }.font(.headline)
            layout {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedDay == nil ? "Личный · сегодня" : "Личный · выбранный день").font(.subheadline).foregroundStyle(.secondary)
                    Text(personal.map { MoneyText.string($0.todayRemaining) } ?? "—")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(personal.map { $0.todayRemaining.minorUnits < 0 } == true ? Color.red : .primary)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    familyLayout {
                        Text("Общий").foregroundStyle(.secondary)
                        Text(family.map { MoneyText.string($0.todayRemaining) } ?? "—").fontWeight(.semibold)
                            .foregroundStyle(family.map { $0.todayRemaining.minorUnits < 0 } == true ? Color.red : .primary)
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    }.font(.subheadline)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                FinancialRings(personal: personal, family: family, compact: true)
                    .frame(width: 94, height: 94).accessibilityHidden(true)
            }
            Divider()
            Text(personal == nil ? "На эту дату личный план не настроен. Семейные записи остаются отдельно." : "Личные и семейные деньги учитываются отдельно.")
                .font(.footnote).foregroundStyle(.secondary)
        }.budgetCard()
    }

    private var familyInvitation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Семья", systemImage: "person.2.fill").font(.title2.bold())
            Text("Семья до пяти человек: общие расходы и накопления, отдельные личные деньги.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Добавить члена семьи", systemImage: "person.badge.plus") { showingFamily = true }
                .buttonStyle(.bordered).controlSize(.large)
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
