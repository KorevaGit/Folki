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
                            options: BudgetScope.allCases.map { ($0.title, $0) }, minimumHeight: 52)
                        Text(scope == .personal ? "Это только твоё 🤫" : "Это общее для всей семьи 💚")
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
                        Text("Ты можешь позвать до 4 близких 🏡 Личные бюджеты у каждого свои.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.folkiPagePadding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .background { FolkiBackground() }
            .navigationTitle("Настройки").toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }.tint(Color.folkiInk)
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
                    Text("Столько ты хочешь потратить за месяц")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Свободно сейчас", value: MoneyText.whole(result.monthlyRemaining))
                    Button { limitsScope = scope } label: {
                        Label("Изменить месячный план", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(FolkiSoftButtonStyle())
                }.budgetCard()
                Text("Пришли деньги? Жми «Внести» 💸")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Плана на месяц пока нет").font(.headline)
                    Text("Две цифры — и Folki скажет, сколько можно тратить в день ✨")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Создать план месяца", systemImage: "plus") { setupScope = scope }
                        .buttonStyle(FolkiSoftButtonStyle()).controlSize(.large)
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
