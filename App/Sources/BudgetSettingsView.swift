import SwiftUI
import FolkiDuoCore

struct BudgetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @State private var setupScope: BudgetScope?
    @State private var limitsScope: BudgetScope?
    @State private var showingFamily = false

    var body: some View {
        NavigationStack {
            Form {
                Section("План на месяц") {
                    plan(personal)
                    plan(family)
                }
                Section {
                    Button { showingFamily = true } label: {
                        Label("Семья и доступ", systemImage: "person.2.fill")
                    }
                } footer: {
                    Text("До пяти человек. Общий бюджет видят все, личные бюджеты остаются у каждого свои.")
                }
                Section("Категории") {
                    NavigationLink("Личные категории") { CategoriesView(session: personal) }
                    NavigationLink("Семейные категории") { CategoriesView(session: family) }
                }
            }
            .navigationTitle("Настройки бюджета").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .sheet(item: $setupScope) { scope in BudgetSetupView(session: scope == .personal ? personal : family) }
            .sheet(item: $limitsScope) { scope in SpendingLimitsView(personal: personal, family: family, scope: scope) }
            .sheet(isPresented: $showingFamily) { SharingView(session: family) }
        }
    }
    @ViewBuilder private func plan(_ session: BudgetSession) -> some View {
        if let result = session.result {
            Button { limitsScope = session.scope } label: {
                LabeledContent(session.scope.title, value: MoneyText.whole(result.monthlyPlan))
            }.foregroundStyle(.primary)
        } else {
            Button("Настроить \(session.scope == .personal ? "личный" : "семейный") план") { setupScope = session.scope }
        }
    }
}
