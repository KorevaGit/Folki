import SwiftUI
import FolkiDuoCore

struct SpendingLimitsView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    let scope: BudgetScope
    @State private var amount: String
    @State private var expected: StoredBudget?
    @State private var errorMessage: String?
    @State private var settingUp = false
    private var session: BudgetSession { scope == .personal ? personal : family }

    init(personal: BudgetSession, family: BudgetSession, scope: BudgetScope) {
        self.personal = personal; self.family = family; self.scope = scope
        let session = scope == .personal ? personal : family
        _amount = State(initialValue: session.household.map { MoneyText.input($0.monthlyFreePlan) } ?? "")
        _expected = State(initialValue: session.storedBudget)
    }
    private var limit: Money? {
        guard let amount = try? MoneyText.parse(amount), amount.minorUnits > 0 else { return nil }
        return amount
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("\(scope.title) бюджет · \(session.referenceDate.formatted(.dateTime.month(.wide).year()))")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.budget(scope))
                    if let expected, expected.snapshot.period.contains(session.referenceDate) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Сколько планируешь потратить за месяц?").font(.headline)
                            HStack(alignment: .firstTextBaseline) {
                                TextField("0", text: $amount).keyboardType(.decimalPad)
                                    .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                                    .accessibilityLabel("План расходов за месяц в рублях")
                                Text(MoneyText.symbol).font(.title2).foregroundStyle(.secondary)
                            }
                            Text("Введи сумму за весь месяц, включая уже совершённые траты.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.budgetCard()
                        if let stats = try? BudgetAnalytics.calculate(records: session.historyRecords, period: .month,
                            anchor: session.referenceDate, asOf: session.referenceDate, calendar: session.calendar) {
                            VStack(alignment: .leading, spacing: 12) {
                                LabeledContent("Уже потрачено из свободных денег", value: MoneyText.whole(stats.flexibleNetSpending))
                                if let limit, let left = try? limit.subtracting(stats.flexibleNetSpending) {
                                    LabeledContent(left.minorUnits < 0 ? "Новый план уже превышен" : "Останется от нового плана") {
                                        Text(MoneyText.whole(left)).monospacedDigit()
                                            .foregroundStyle(left.minorUnits < 0 ? Color.red : .primary)
                                    }
                                }
                            }.font(.subheadline).budgetCard()
                        }
                        Text("Меняется только план расходов. Деньги и записи останутся прежними. Ориентир дня рассчитывается из свободного остатка и от этого изменения не увеличится.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(action: save) {
                            Text("Сохранить план").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                        }.buttonStyle(.glassProminent).disabled(limit == nil)
                    } else {
                        Text("На текущий месяц ещё нет плана.").font(.headline)
                        Button("Создать план месяца") { settingUp = true }.buttonStyle(.glass).controlSize(.large)
                    }
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                }.folkiPagePadding()
            }
            .background { FolkiBackground() }
            .navigationTitle("План").toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }
                }
            }
            .sheet(isPresented: $settingUp, onDismiss: reload) { BudgetSetupView(session: session) }
        }
    }
    private func save() {
        guard let limit, let expected else { return }
        do { try session.updateSpendingLimit(limit, expected: expected); FolkiFeedback.saved(); dismiss() }
        catch LedgerError.conflict { errorMessage = "План уже изменился. Закрой экран и открой его снова." }
        catch { errorMessage = "Не удалось сохранить план. Проверь сумму и доступ к бюджету." }
    }
    private func reload() {
        expected = session.storedBudget
        amount = session.household.map { MoneyText.input($0.monthlyFreePlan) } ?? ""
        errorMessage = nil
    }
}
