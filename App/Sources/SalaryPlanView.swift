import SwiftUI
import FolkiDuoCore

private struct ReserveDraft: Identifiable {
    var id = UUID()
    var name: String
    var amount = ""
    var isRegularPayment: Bool

    var reserve: ProtectedReserve? {
        guard let value = try? Money(parsing: amount), value.minorUnits >= 0,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ProtectedReserve(id: id, name: name, openingAmount: value, isRegularPayment: isRegularPayment)
    }
}

/// The same plan is available after onboarding, in settings and when salary arrives.
struct BudgetSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    var editingCurrent = false
    @State private var available = ""
    @State private var payday = Date.now
    @State private var planning = false
    @State private var drafts: [ReserveDraft] = []
    @State private var expected: StoredBudget?
    @State private var errorMessage: String?
    @State private var initialized = false

    private var minimumPayday: Date {
        session.calendar.date(byAdding: .day, value: 1, to: session.calendar.startOfDay(for: session.referenceDate))!
    }
    private var goalFunds: Money {
        let source = editingCurrent ? session.household?.reserves.filter { reserve in session.goals.contains { $0.id == reserve.id } }.map(\.openingAmount)
            : session.goals.map(\.balance)
        return (try? (source ?? []).reduce(Money(minorUnits: 0)) { try $0.adding($1) }) ?? Money(minorUnits: 0)
    }
    private var values: (funds: Money, free: Money, reserves: [ProtectedReserve])? {
        guard let funds = try? MoneyText.parse(available), funds.minorUnits > 0 else { return nil }
        var reserves: [ProtectedReserve] = []
        if planning {
            for draft in drafts {
                if draft.amount.isEmpty { continue }
                guard let reserve = draft.reserve else { return nil }
                reserves.append(reserve)
            }
        }
        guard let protected = try? reserves.reduce(goalFunds, { try $0.adding($1.openingAmount) }),
              let free = try? funds.subtracting(protected), free.minorUnits >= 0 else { return nil }
        return (funds, free, reserves)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(editingCurrent ? "Деньги на начало периода" : "Сколько денег есть сейчас", text: $available)
                        .keyboardType(.decimalPad)
                    if editingCurrent {
                        LabeledContent("Период", value: session.periodTitle)
                    } else {
                        DatePicker("Следующая зарплата", selection: $payday, in: minimumPayday..., displayedComponents: .date)
                    }
                } header: { Text(editingCurrent ? "Зарплата и остаток, ₽" : "До зарплаты, ₽") } footer: {
                    Text(editingCurrent ? "Сумма на начало периода: зарплата, остаток и накопления. Уже записанные траты сохранятся."
                         : "Всё, что есть на картах и наличными, включая накопления. В день следующей зарплаты начнётся новый период.")
                }
                if !editingCurrent {
                    Section { Toggle("Составить план по зарплате", isOn: $planning) }
                }
                if planning {
                    Section {
                        ForEach(drafts.filter(\.isRegularPayment)) { draft in reserveRow(binding(draft.id)) }
                            .onDelete { offsets in delete(offsets, regular: true) }
                        Menu("Добавить платёж", systemImage: "plus") {
                            ForEach([String(localized: "Жильё и коммуналка"), String(localized: "Связь и подписки"), String(localized: "Кредит"), String(localized: "Другой платёж")], id: \.self) { name in
                                Button(name) { drafts.append(ReserveDraft(name: name, isRegularPayment: true)) }
                            }
                        }
                    } header: { Text("Регулярные платежи") } footer: {
                        Text("Folki отложит их отдельно от дневных денег. При оплате выбери платёж в поле «Источник» — дневное кольцо не изменится.")
                    }
                    Section {
                        ForEach(drafts.filter { !$0.isRegularPayment }) { draft in reserveRow(binding(draft.id)) }
                            .onDelete { offsets in delete(offsets, regular: false) }
                        if !drafts.contains(where: { !$0.isRegularPayment }) {
                            Button("Отложить в копилку", systemImage: "plus") {
                                drafts.append(ReserveDraft(name: String(localized: "Копилка"), isRegularPayment: false))
                            }
                        }
                        if goalFunds.minorUnits > 0 { LabeledContent("В целях накоплений", value: MoneyText.whole(goalFunds)) }
                    } header: { Text("Сколько отложить") } footer: { Text("Копилка и цели не входят в кольца расходов.") }
                }
                if let values {
                    Section("На повседневные траты") {
                        LabeledContent("На весь период", value: MoneyText.whole(values.free))
                        if !editingCurrent,
                           let period = try? BudgetPeriod.untilPayday(from: session.referenceDate, payday: payday,
                               timeZoneIdentifier: session.calendar.timeZone.identifier),
                           let days = try? period.remainingDays(including: session.referenceDate),
                           let allocation = try? DailyAllocation(total: values.free, days: days) {
                            LabeledContent("Сегодня можно", value: MoneyText.whole(allocation.firstDayAmount))
                            Text("До зарплаты \(days) дн.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else if !available.isEmpty {
                    Text("Проверь суммы: платежи и накопления должны помещаться в доступные деньги.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !editingCurrent, session.result != nil {
                    Section {
                        Text("Текущий период завершится сейчас. Его операции останутся в истории. Введи весь остаток после поступления зарплаты.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }
            .folkiFormLayout()
            .navigationTitle(editingCurrent ? "План по зарплате" : session.periodEnded ? "Пришла зарплата?" : "До зарплаты")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.calendar, session.calendar).environment(\.timeZone, session.calendar.timeZone)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingCurrent ? "Сохранить" : "Начать", action: save).disabled(values == nil)
                }
            }
            .onAppear(perform: initialize)
        }
    }

    private func reserveRow(_ draft: Binding<ReserveDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Название", text: draft.name)
            HStack {
                TextField("Сумма", text: draft.amount).keyboardType(.decimalPad).monospacedDigit()
                Text(MoneyText.symbol).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
    private func delete(_ offsets: IndexSet, regular: Bool) {
        let rows = drafts.filter { $0.isRegularPayment == regular }
        let ids = offsets.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
        drafts.removeAll { ids.contains($0.id) }
    }
    private func binding(_ id: UUID) -> Binding<ReserveDraft> {
        Binding(get: { drafts.first { $0.id == id } ?? ReserveDraft(id: id, name: "", isRegularPayment: false) },
                set: { value in if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index] = value } })
    }
    private func initialize() {
        guard !initialized else { return }; initialized = true
        expected = session.storedBudget
        payday = session.calendar.date(byAdding: .month, value: 1, to: session.referenceDate) ?? minimumPayday
        planning = editingCurrent
        if editingCurrent { available = session.household.map { MoneyText.input($0.openingFunds) } ?? "" }
        drafts = (session.household?.reserves ?? []).filter { reserve in !session.goals.contains { $0.id == reserve.id } }
            .filter { $0.openingAmount.minorUnits > 0 }
            .map { ReserveDraft(id: editingCurrent ? $0.id : UUID(), name: $0.name,
                amount: MoneyText.input($0.openingAmount), isRegularPayment: $0.isRegularPayment) }
        if !drafts.contains(where: { !$0.isRegularPayment }) {
            drafts.append(ReserveDraft(name: String(localized: "Копилка"), isRegularPayment: false))
        }
    }
    private func save() {
        guard let values else { return }
        do {
            if editingCurrent, let expected {
                try session.updateSalaryPlan(available: values.funds, reserves: values.reserves, expected: expected)
            } else {
                try session.createPlan(monthlyPlan: values.free, available: values.funds, reserves: values.reserves,
                    payday: payday, closeCurrent: session.result != nil)
            }
            FolkiFeedback.saved(); dismiss()
        } catch LedgerError.conflict {
            errorMessage = String(localized: "Бюджет уже изменился. Закрой форму и открой её снова.")
        } catch BudgetError.insufficientReserve {
            errorMessage = String(localized: "Из этих денег уже были траты. Оставь для платежа не меньше оплаченной суммы и проверь свободный остаток.")
        } catch {
            errorMessage = String(localized: "Не получилось сохранить. Проверь суммы, дату и доступ к бюджету.")
        }
    }
}
