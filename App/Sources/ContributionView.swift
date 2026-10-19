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
                        LabeledContent("Свободно в личном", value: MoneyText.string(available))
                    }
                } footer: {
                    Text("Деньги уйдут из вашего личного бюджета в семейный. Это не трата: лимиты и аналитика расходов не изменятся. Участники семьи увидят ваш взнос, но не ваш личный бюджет.")
                }
                if let money, let available, let familyMonth = family.result?.monthlyRemaining,
                   let personalAfter = try? available.subtracting(money), let familyAfter = try? familyMonth.adding(money) {
                    Section("После перевода") {
                        LabeledContent("Личный · месяц", value: MoneyText.string(personalAfter))
                        LabeledContent("Семейный · месяц", value: MoneyText.string(familyAfter))
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
