import SwiftUI
import FolkiDuoCore

struct SpendingLimitsView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @State private var scope: BudgetScope
    @State private var amount: String
    @State private var expected: StoredBudget?
    @State private var errorMessage: String?
    @State private var settingUp = false
    private var session: BudgetSession { scope == .personal ? personal : family }

    init(personal: BudgetSession, family: BudgetSession, scope: BudgetScope) {
        self.personal = personal; self.family = family
        let session = scope == .personal ? personal : family
        _scope = State(initialValue: scope)
        _amount = State(initialValue: session.household.map { MoneyText.input($0.monthlyFreePlan) } ?? "")
        _expected = State(initialValue: session.storedBudget)
    }
    private var limit: Money? {
        guard let amount = try? MoneyText.parse(amount, preserving: expected?.snapshot.monthlyFreePlan), amount.minorUnits > 0 else { return nil }
        return amount
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Бюджет", selection: $scope) {
                    ForEach(BudgetScope.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if let expected, expected.snapshot.period.contains(session.referenceDate) {
                    Section {
                        TextField("Лимит, \(CurrencyDisplay.shared.symbol)", text: $amount).keyboardType(.decimalPad)
                        if let stats = try? BudgetAnalytics.calculate(records: session.historyRecords, period: .month,
                            anchor: session.referenceDate, asOf: session.referenceDate, calendar: session.calendar) {
                            LabeledContent("Свободные траты за месяц", value: MoneyText.string(stats.flexibleNetSpending))
                            if let limit, let left = try? limit.subtracting(stats.flexibleNetSpending) {
                                LabeledContent("До лимита") {
                                    Text(MoneyText.string(left)).foregroundStyle(left.minorUnits < 0 ? Color.red : .primary)
                                }
                            }
                        }
                    } header: { Text("Месячный лимит расходов") } footer: {
                        Text("Лимит — плановая граница свободных трат с учётом возвратов. Оплаты из защищённых резервов учитываются отдельно. Изменение лимита не создаёт деньги и не меняет операции; дневной ориентир считается из доступного остатка.")
                    }
                } else {
                    Section {
                        Text("На текущий месяц нужен план бюджета.").foregroundStyle(.secondary)
                        Button("Создать план") { settingUp = true }
                    }
                }
                NavigationLink("Мягкие лимиты категорий") { CategoryLimitsView(session: session) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Лимиты").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard let limit, let expected else { return }
                        do { try session.updateSpendingLimit(limit, expected: expected); dismiss() }
                        catch LedgerError.conflict { errorMessage = "Лимит уже изменился. Закройте настройки и откройте заново." }
                        catch { errorMessage = "Лимит не сохранён. Проверьте сумму и доступ к бюджету." }
                    }.disabled(limit == nil || expected == nil || expected?.snapshot.period.contains(session.referenceDate) != true)
                }
            }
            .onChange(of: scope) { reload() }
            .sheet(isPresented: $settingUp, onDismiss: reload) { BudgetSetupView(session: session) }
        }
    }
    private func reload() {
        expected = session.storedBudget
        amount = session.household.map { MoneyText.input($0.monthlyFreePlan) } ?? ""
        errorMessage = nil
    }
}
