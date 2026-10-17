import SwiftUI
import FolkiDuoCore

struct BudgetSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    @State private var monthly = ""
    @State private var available = ""
    @State private var errorMessage: String?

    private var validated: (Money, Money)? {
        guard let plan = try? Money(parsing: monthly), plan.minorUnits > 0,
              let funds = try? Money(parsing: available), funds.minorUnits >= 0 else { return nil }
        return (plan, funds)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("План на месяц", text: $monthly).keyboardType(.decimalPad)
                    TextField("Осталось сейчас", text: $available).keyboardType(.decimalPad)
                } header: {
                    Text("Свободный бюджет, ₽")
                } footer: {
                    Text("Укажите суммы после исключения обязательных платежей и накоплений. Настройка отдельных резервов появится на следующем этапе.")
                }
                Section {
                    Text("Данные этой сборки хранятся только до закрытия приложения.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Настроить бюджет").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        guard let values = validated else { return }
                        do {
                            try session.createPlan(monthlyPlan: values.0, available: values.1)
                            dismiss()
                        } catch { errorMessage = "Проверьте суммы бюджета." }
                    }.disabled(validated == nil)
                }
            }
        }
    }
}

struct ExpenseEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    @State private var amount = ""
    @State private var title = ""
    @State private var payerID: UUID
    @State private var errorMessage: String?

    init(session: BudgetSession) {
        self.session = session
        _payerID = State(initialValue: session.members[0].id)
    }

    private var money: Money? {
        guard let value = try? Money(parsing: amount), value.minorUnits > 0 else { return nil }
        return value
    }

    private var impact: PurchaseImpact? {
        guard let money, let result = session.result else { return nil }
        return try? PurchaseImpactCalculator.preview(amount: money, against: result)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Сумма, ₽") {
                    TextField("0", text: $amount).keyboardType(.decimalPad).font(.largeTitle.bold())
                    if !amount.isEmpty && money == nil {
                        Text("Введите положительную сумму, не более двух знаков после запятой.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("На что потратили", text: $title)
                    Picker("Оплатил", selection: $payerID) {
                        ForEach(session.members) { Text($0.name).tag($0.id) }
                    }
                }
                if let impact {
                    Section("После записи") {
                        if impact.todayRemaining.minorUnits < 0 {
                            LabeledContent("Сегодня сверх плана", value: MoneyText.string(Money(minorUnits: -impact.todayRemaining.minorUnits)))
                        } else {
                            LabeledContent("Сегодня останется", value: MoneyText.string(impact.todayRemaining))
                        }
                        if impact.monthlyRemaining.minorUnits < 0 {
                            Text("Свободный бюджет будет превышен. Пересмотрите план.")
                        } else if let allocation = impact.futureAllocation {
                            LabeledContent("Далее в день", value: "≈\(MoneyText.string(allocation.firstDayAmount))")
                            Text("На \(allocation.days) дн., если сегодня больше не тратить.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Сегодня последний день периода.").font(.caption)
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Новый расход").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Записать") {
                        guard let money else { return }
                        do {
                            try session.addExpense(amount: money, title: title, payerID: payerID)
                            dismiss()
                        } catch { errorMessage = "Не удалось сохранить. Проверьте сумму и период бюджета." }
                    }.disabled(money == nil || impact == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
