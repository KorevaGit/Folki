import SwiftUI
import FolkiDuoCore

struct BudgetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @State private var setupScope: BudgetScope?

    var body: some View {
        NavigationStack {
            Form {
                Section("Планы бюджета") {
                    plan(personal)
                    plan(family)
                }
            }
            .navigationTitle("Настройки бюджета").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .sheet(item: $setupScope) { scope in BudgetSetupView(session: scope == .personal ? personal : family) }
        }
    }
    @ViewBuilder private func plan(_ session: BudgetSession) -> some View {
        if let result = session.result {
            LabeledContent(session.scope.title + " лимит", value: MoneyText.string(result.monthlyPlan))
        } else {
            Button("Настроить \(session.scope == .personal ? "личный" : "семейный") план") { setupScope = session.scope }
        }
    }
}

extension Color {
    static var folkiAccent: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.38, green: 0.74, blue: 0.89, alpha: 1)
                : UIColor(red: 0.16, green: 0.30, blue: 0.55, alpha: 1)
        })
    }
}
