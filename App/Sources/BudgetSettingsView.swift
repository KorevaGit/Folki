import SwiftUI
import FolkiDuoCore

struct BudgetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @State private var scope: BudgetScope = .personal
    @State private var setupScope: BudgetScope?
    @State private var limitsScope: BudgetScope?
    @State private var showingFamily = false
    private var session: BudgetSession { scope == .personal ? personal : family }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Какой бюджет настроим?").font(.headline)
                        FolkiSegmentedPicker(title: "Бюджет", selection: $scope,
                            options: BudgetScope.allCases.map { ($0.title, $0) }, minimumHeight: 64)
                        Text(scope == .personal ? "Личные суммы и категории видишь только ты." : "Семейный план и категории общие для участников семьи.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    plan
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Категории расходов").font(.system(.title2, design: .rounded, weight: .bold))
                        NavigationLink { CategoriesView(session: session).id(scope) } label: {
                            settingsRow("Настроить категории", subtitle: "Добавить свою, изменить значок или убрать в архив", symbol: "square.grid.2x2")
                        }.buttonStyle(.plain).budgetCard()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Семья и доступ").font(.system(.title2, design: .rounded, weight: .bold))
                        FamilyMembersCard(family: family) { showingFamily = true }
                        Text("До пяти человек. Семейный бюджет общий, личные бюджеты друг другу не видны.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.folkiPagePadding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .background { FolkiBackground() }
            .navigationTitle("Настройки").toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }
                }
            }
            .sheet(item: $setupScope) { scope in BudgetSetupView(session: scope == .personal ? personal : family) }
            .sheet(item: $limitsScope) { scope in SpendingLimitsView(personal: personal, family: family, scope: scope) }
            .sheet(isPresented: $showingFamily) { SharingView(session: family) }
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("План на месяц").font(.system(.title2, design: .rounded, weight: .bold))
            if let result = session.result {
                VStack(alignment: .leading, spacing: 16) {
                    Text(session.referenceDate, format: .dateTime.month(.wide).year()).font(.subheadline).foregroundStyle(.secondary)
                    Text(MoneyText.whole(result.monthlyPlan))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Color.budget(scope)).lineLimit(1).minimumScaleFactor(0.5)
                    Text("Столько ты планируешь потратить за месяц из свободных денег.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Свободно сейчас", value: MoneyText.whole(result.monthlyRemaining))
                    Button { limitsScope = scope } label: {
                        Label("Изменить месячный план", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.glass)
                }.budgetCard()
                Text("План — ориентир расходов. Его изменение не пополняет бюджет. Новые деньги добавляются через «Внести». Ориентир дня считается из свободного остатка, а не из плана.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("План на текущий месяц ещё не создан").font(.headline)
                    Text("Укажи план расходов и сколько денег уже есть. После этого появится ориентир на день.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Создать план месяца", systemImage: "plus") { setupScope = scope }
                        .buttonStyle(.glass).controlSize(.large)
                }.budgetCard()
            }
        }
    }

    private func settingsRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.folkiAccent).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).foregroundStyle(Color.folkiInk)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.frame(minHeight: 60).contentShape(Rectangle())
    }
}
