import SwiftUI
import FolkiDuoCore

/// Moves money from the personal budget into the family one. Neither side counts as spending.
struct ContributionView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @State private var linkID = UUID()
    @State private var amount = ""
    @State private var errorMessage: String?
    private var available: Money? { personal.result?.monthlyRemaining }
    private var money: Money? {
        guard let money = try? MoneyText.parse(amount), money.minorUnits > 0,
              let available, money.minorUnits <= available.minorUnits else { return nil }
        return money
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Сумма, \(MoneyText.symbol)", text: $amount).keyboardType(.decimalPad).font(.largeTitle.bold())
                    if let available {
                        LabeledContent("Свободно в личном", value: MoneyText.whole(available))
                    }
                } footer: {
                    Text("Деньги уйдут из твоего личного бюджета в семейный. Это не трата: лимиты и аналитика расходов не изменятся. Семья увидит взнос, но не твой личный бюджет.")
                }
                if let money, let personalBefore = personal.result, let familyBefore = family.result,
                   let personalAfter = personal.previewTransfer(money, kind: .contributionOut),
                   let familyAfter = family.previewTransfer(money, kind: .contributionIn) {
                    Section("После перевода") {
                        ImpactLines(before: personalBefore, after: personalAfter, label: "Личный").frame(maxWidth: .infinity)
                        ImpactLines(before: familyBefore, after: familyAfter, label: "Семейный").frame(maxWidth: .infinity)
                    }
                } else if !amount.isEmpty {
                    Text("Сумма должна быть больше нуля и не больше свободного остатка личного бюджета.").foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Взнос в семейный").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Перевести") {
                        guard let money else { return }
                        do { try personal.contribute(money, to: family, linkID: linkID); dismiss() }
                        catch BudgetError.insufficientReserve { errorMessage = "В личном бюджете недостаточно свободных денег." }
                        catch { errorMessage = "Не удалось перевести. Данные формы остались здесь; попробуйте снова." }
                    }.disabled(money == nil)
                }
            }
        }
    }
}
