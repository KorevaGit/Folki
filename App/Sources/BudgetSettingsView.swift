import SwiftUI
import FolkiDuoCore

struct BudgetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @State private var scope: BudgetScope = .personal
    @State private var setupScope: BudgetScope?
    @State private var limitsScope: BudgetScope?
    @State private var salaryScope: BudgetScope?
    @State private var showingFamily = false
    @State private var showingDistribution = false
    @State private var errorMessage: String?
    private var session: BudgetSession { scope == .personal ? personal : family }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Какой бюджет настроим?").font(.headline)
                        if family.household != nil { FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: $scope,
                            options: BudgetScope.allCases.map { ($0.title, $0) }, minimumHeight: 52) }
                        Text(scope == .personal ? String(localized: "Это только твоё 🤫") : String(localized: "Это общее для всей семьи 💚"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    plan
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Категории расходов").font(.system(.title2, design: .rounded, weight: .bold))
                        NavigationLink { CategoriesView(session: session).id(scope) } label: {
                            settingsRow(String(localized: "Настроить категории"), subtitle: String(localized: "Добавить свою, изменить значок или убрать в архив"), symbol: "square.grid.2x2")
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
            .sheet(item: $setupScope) { scope in DailyFundingView(personal: personal, family: family, initialScope: scope) }
            .sheet(item: $limitsScope) { scope in SpendingLimitsView(personal: personal, family: family, scope: scope) }
            .sheet(item: $salaryScope) { scope in BudgetSetupView(session: scope == .personal ? personal : family, editingCurrent: true) }
            .sheet(isPresented: $showingDistribution) {
                DistributionChoiceView(day: Binding(get: { session.distributionDay }, set: { session.distributionDay = $0 }),
                    apply: { try session.setDistributionDay($0) })
            }
            .sheet(isPresented: $showingFamily) { SharingView(session: family) }
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("На каждый день").font(.system(.title2, design: .rounded, weight: .bold))
            VStack(alignment: .leading, spacing: 16) {
                if let result = session.result, session.hasFunding {
                    LabeledContent("Сегодня можно", value: MoneyText.whole(result.todayRemaining))
                    LabeledContent("Осталось", value: MoneyText.whole(result.monthlyRemaining))
                }
                Button(distributionTitle(session.distributionDay)) { showingDistribution = true }
                    .font(.subheadline)
                Button("Внести деньги", systemImage: "plus") { setupScope = scope }.buttonStyle(FolkiSoftButtonStyle())
            }.budgetCard()
            Button("Все финансы и конверты", systemImage: "tray.2") {
                do {
                    try session.ensureDailyPeriod(); session.fullFinanceEnabled = true; salaryScope = scope
                } catch { errorMessage = String(localized: "Не получилось открыть бюджет. Попробуй ещё раз.") }
            }.buttonStyle(FolkiSoftButtonStyle())
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
