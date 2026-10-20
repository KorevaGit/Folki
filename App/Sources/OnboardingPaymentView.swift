import SwiftUI
import FolkiDuoCore

struct OnboardingPayment: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var amount: String
    var dueDate: Date
    var reserveNow: Bool
    var scopeRaw: String
    var scope: BudgetScope { BudgetScope(rawValue: scopeRaw) ?? .personal }
    @MainActor var money: Money? { try? MoneyText.parse(amount) }
}

struct OnboardingPaymentView: View {
    let hasFamily: Bool
    let available: (BudgetScope) -> Money
    let save: (OnboardingPayment) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amount = ""
    @State private var date = Date.now
    @State private var reserveNow = false
    @State private var scope: BudgetScope = .personal
    private var money: Money? { (try? MoneyText.parse(amount)).flatMap { $0.minorUnits > 0 ? $0 : nil } }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80 && money != nil &&
            (!reserveNow || money!.minorUnits <= available(scope).minorUnits)
    }
    var body: some View {
        NavigationStack {
            Form {
                if hasFamily { Picker("Бюджет", selection: $scope) {
                    ForEach(BudgetScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented) }
                Section {
                    TextField("Название платежа", text: $name)
                    TextField("Сумма", text: $amount).keyboardType(.decimalPad)
                    DatePicker("Оплатить до", selection: $date, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                }
                Section {
                    Toggle("Учесть в этой сумме", isOn: $reserveNow)
                    if reserveNow {
                        if let money, money.minorUnits <= available(scope).minorUnits,
                           let free = try? available(scope).subtracting(money) {
                            LabeledContent("На каждый день останется", value: MoneyText.whole(free))
                        } else if money != nil {
                            Text("Сумма больше бюджета. Добавь конверт без вычета или измени сумму.").foregroundStyle(.secondary)
                        } else {
                            LabeledContent("В бюджете сейчас", value: MoneyText.whole(available(scope)))
                        }
                    }
                } footer: {
                    Text(reserveNow ? "Деньги останутся в конверте до оплаты и не попадут в дневной остаток."
                         : "Сохраним сумму и дату. Деньги из повседневного бюджета пока не вычитаются.")
                }
            }.folkiFormLayout().navigationTitle("Конверт").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(reserveNow ? "Учесть" : "Добавить с датой") {
                            guard valid else { return }
                            save(OnboardingPayment(name: name.trimmingCharacters(in: .whitespacesAndNewlines), amount: amount,
                                dueDate: date, reserveNow: reserveNow, scopeRaw: scope.rawValue))
                            dismiss()
                        }.disabled(!valid)
                    }
                }.onAppear { reserveNow = available(scope).minorUnits > 0 }
        }
    }
}
