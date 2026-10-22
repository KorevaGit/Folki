import SwiftUI
import UIKit
import FolkiDuoCore

/// Settings: the budget's period and categories, the family, notifications and the app. No money moves here.
struct BudgetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @State private var scope: BudgetScope = .personal
    @State private var showingFamily = false
    @State private var showingDistribution = false
    private var session: BudgetSession { scope == .personal ? personal : family }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if family.household != nil {
                        Picker("Бюджет", selection: $scope) {
                            ForEach(BudgetScope.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                    Button { showingDistribution = true } label: {
                        LabeledContent("Период", value: periodRuleTitle(session.periodRule))
                    }.foregroundStyle(Color.folkiInk)
                    NavigationLink { CategoriesView(session: session).id(scope) } label: { Text("Категории") }
                } header: { Text("Бюджет") } footer: {
                    Text(scope == .personal ? "Личный бюджет видишь только ты." : "Семейный бюджет видят все участники.")
                }
                Section("Семья") {
                    ForEach(family.members.filter(\.isActive)) { member in
                        HStack(spacing: FolkiSpacing.item) {
                            MemberAvatar(name: member.name)
                            Text(family.memberName(member.id))
                            Spacer()
                            if member.id == family.authorID { Text("Ты").foregroundStyle(.secondary) }
                        }
                    }
                    Button(family.household == nil ? "Позвать в семью" : "Участники и доступ", systemImage: "person.badge.plus") {
                        showingFamily = true
                    }
                }
                Section("Уведомления") {
                    Button("Настройки уведомлений", systemImage: "bell") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("Приложение") {
                    LabeledContent("iCloud", value: personal.repository?.statusText ?? String(localized: "Демонстрационный режим"))
                    LabeledContent("Версия", value: version)
                }
            }
            .folkiFormLayout()
            .navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .sheet(isPresented: $showingDistribution) {
                DistributionChoiceView(current: session.periodRule, apply: { try session.setPeriodRule($0) })
            }
            .sheet(isPresented: $showingFamily) { SharingView(session: family) }
        }
    }
}
