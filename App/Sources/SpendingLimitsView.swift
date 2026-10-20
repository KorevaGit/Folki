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
                    Text("\(scope.title) бюджет · \(session.periodTitle)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.budget(scope))
                    if let expected, expected.snapshot.period.contains(session.referenceDate) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Сколько планируешь потратить на повседневное?").font(.headline)
                            HStack(alignment: .firstTextBaseline) {
                                TextField("0", text: $amount).keyboardType(.decimalPad)
                                    .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                                    .accessibilityLabel("План расходов за период в рублях")
                                Text(MoneyText.symbol).font(.title2).foregroundStyle(.secondary)
                            }
                            Text("Сумма на весь период с учётом прошлых трат. Регулярные платежи — отдельно.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.budgetCard()
                        if let stats = try? session.analytics(.month, on: session.referenceDate) {
                            VStack(alignment: .leading, spacing: 12) {
                                LabeledContent("Уже потрачено из свободных денег", value: MoneyText.whole(stats.flexibleNetSpending))
                                if let limit, let left = try? limit.subtracting(stats.flexibleNetSpending) {
                                    LabeledContent(left.minorUnits < 0 ? String(localized: "Новый план уже превышен") : String(localized: "Останется от нового плана")) {
                                        Text(MoneyText.whole(left)).monospacedDigit()
                                            .foregroundStyle(left.minorUnits < 0 ? Color.red : .primary)
                                    }
                                }
                            }.font(.subheadline).budgetCard()
                        }
                        Text("Это только план — деньги и записи никуда не денутся 👌")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(action: save) {
                            Text("Сохранить план").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                        }.buttonStyle(FolkiPrimaryButtonStyle()).disabled(limit == nil)
                    } else {
                        Text("Плана на этот период пока нет").font(.headline)
                        Button("Создать план периода") { settingUp = true }.buttonStyle(FolkiSoftButtonStyle()).controlSize(.large)
                    }
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                }.folkiPagePadding()
            }
            .background { FolkiBackground() }
            .navigationTitle("План").toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }.tint(Color.folkiInk)
                }
            }
            .sheet(isPresented: $settingUp, onDismiss: reload) { BudgetSetupView(session: session) }
        }
    }
    private func save() {
        guard let limit, let expected else { return }
        do { try session.updateSpendingLimit(limit, expected: expected); FolkiFeedback.saved(); dismiss() }
        catch LedgerError.conflict { errorMessage = String(localized: "План уже изменился. Закрой экран и открой его снова.") }
        catch { errorMessage = String(localized: "Не получилось сохранить план. Проверь сумму и доступ к бюджету.") }
    }
    private func reload() {
        expected = session.storedBudget
        amount = session.household.map { MoneyText.input($0.monthlyFreePlan) } ?? ""
        errorMessage = nil
    }
}
