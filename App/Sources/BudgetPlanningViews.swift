import SwiftUI
import FolkiDuoCore

struct BudgetPlansView: View {
    let session: BudgetSession
    @State private var addingBill = false
    @State private var addingIncome = false
    @State private var errorMessage: String?
    @State private var confirmingBill: ObligationSnapshot?
    @State private var confirmingIncome: ExpectedIncomeSnapshot?
    var body: some View {
        List {
            Section { CashPlanCard(session: session) }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            Section {
                Button("Добавить платёж", systemImage: "calendar.badge.plus") { addingBill = true }
                ForEach(session.obligations.filter(\.isPending)) { bill in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(bill.name).font(.headline); Spacer(); Text(MoneyText.string(bill.amount)).monospacedDigit() }
                        Text("\(bill.dueDate.formatted(date: .abbreviated, time: .omitted)) · \(bill.recurrence.title)").font(.caption).foregroundStyle(.secondary)
                        Text(bill.reserved == bill.amount ? "Деньги защищены в резерве" : "Нужно зарезервировать \(MoneyText.string(bill.amount))")
                            .font(.subheadline).foregroundStyle(bill.reserved == bill.amount ? Color.secondary : .orange)
                        if bill.reserved == bill.amount {
                            Button("Отметить оплаченным") { confirmingBill = bill }.buttonStyle(.bordered)
                        } else {
                            Button("Зарезервировать") { perform { try session.billAction(bill, action: "reserve") } }.buttonStyle(.bordered)
                        }
                        Button("Отменить платёж и освободить резерв", role: .destructive) { perform { try session.billAction(bill, action: "cancel") } }.font(.caption)
                    }.padding(.vertical, 6)
                }
                if session.obligations.filter(\.isPending).isEmpty { Text("Добавьте аренду, подписки, кредит или ежегодный платёж.").foregroundStyle(.secondary) }
            } header: { Text("Календарь платежей") } footer: {
                Text("Оплата создаёт одну запись из резерва. Следующий повтор появится без резервирования: его нужно подтвердить отдельно. Это учёт платежа, а не банковский перевод.")
            }
            Section("Ожидаемые доходы") {
                Button("Запланировать доход", systemImage: "plus.circle") { addingIncome = true }
                ForEach(session.expectedIncomes.filter(\.isPending)) { income in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(income.name).font(.headline); Spacer(); Text(MoneyText.string(income.amount)).monospacedDigit() }
                        Text("\(income.dueDate.formatted(date: .abbreviated, time: .omitted)) · \(income.recurrence.title)").font(.caption).foregroundStyle(.secondary)
                        Button("Подтвердить получение") { confirmingIncome = income }.buttonStyle(.bordered)
                        Button("Отменить ожидание", role: .destructive) { perform { try session.incomeAction(income, receive: false) } }.font(.caption)
                    }.padding(.vertical, 6)
                }
                Text("Ожидания не входят в доступный остаток. Подтверждение добавит поступление в свободные деньги датой получения.").font(.footnote).foregroundStyle(.secondary)
            }
            if session.incomeJustReceived { Section { IncomeSavingsSuggestions(session: session) } }
            Section("Недавно выполнено") {
                ForEach(session.obligations.filter { !$0.isPending }.suffix(5)) { bill in
                    Label("\(bill.name) · \(bill.paidAt == nil ? "отменён" : "оплачен")", systemImage: bill.paidAt == nil ? "xmark.circle" : "checkmark.circle")
                }
                ForEach(session.expectedIncomes.filter { !$0.isPending }.suffix(5)) { income in
                    Label("\(income.name) · \(income.receivedAt == nil ? "отменён" : "получен")", systemImage: "checkmark.circle")
                }
            }
        }
        .navigationTitle("Платежи и доходы").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .disabled(session.result == nil || session.isDemo)
        .sheet(isPresented: $addingBill) { PlannedEntryForm(session: session, isIncome: false) }
        .sheet(isPresented: $addingIncome) { PlannedEntryForm(session: session, isIncome: true) }
        .confirmationDialog("Записать оплату из резерва?", isPresented: Binding(get: { confirmingBill != nil }, set: { if !$0 { confirmingBill = nil } }), titleVisibility: .visible) {
            if let bill = confirmingBill { Button("Оплачено: \(MoneyText.string(bill.amount))") { perform { try session.billAction(bill, action: "pay") } } }
        }
        .confirmationDialog("Доход уже получен?", isPresented: Binding(get: { confirmingIncome != nil }, set: { if !$0 { confirmingIncome = nil } }), titleVisibility: .visible) {
            if let income = confirmingIncome { Button("Получено: \(MoneyText.string(income.amount))") { perform { try session.incomeAction(income, receive: true) } } }
        }
        .alert("Не удалось сохранить", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("Готово") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = "Проверьте свободный остаток и актуальность плана. Изменения не применены." }
    }
}

private struct PlannedEntryForm: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    let isIncome: Bool
    @State private var name = ""
    @State private var amount = ""
    @State private var due = Date.now
    @State private var recurrence = PaymentRecurrence.once
    @State private var category = ExpenseCategory.home
    @State private var reserve = true
    @State private var errorMessage: String?
    private var money: Money? { guard let value = try? MoneyText.parse(amount), value.minorUnits > 0 else { return nil }; return value }
    var body: some View {
        NavigationStack {
            Form {
                Section(session.scope.title + " бюджет") {
                    TextField(isIncome ? "Название дохода" : "Название платежа", text: $name)
                    TextField("Сумма, \(CurrencyDisplay.shared.symbol)", text: $amount).keyboardType(.decimalPad)
                    DatePicker("Дата", selection: $due, displayedComponents: .date)
                    Picker("Повтор", selection: $recurrence) { ForEach(PaymentRecurrence.allCases) { Text($0.title).tag($0) } }
                    if !isIncome {
                        Picker("Категория", selection: $category) { ForEach(ExpenseCategory.allCases, id: \.self) { Text($0.title).tag($0) } }
                        Toggle("Зарезервировать сейчас", isOn: $reserve)
                        if reserve, let money, let free = session.result?.monthlyRemaining, let remaining = try? free.subtracting(money) {
                            LabeledContent("Останется свободно") { Text(MoneyText.string(remaining)).foregroundStyle(remaining.minorUnits < 0 ? Color.red : .primary) }
                        }
                        Text("Резерв уменьшает свободные деньги, не создавая расход. Если денег не хватает, сохраните платёж без резервирования.").font(.footnote).foregroundStyle(.secondary)
                    } else { Text("Это только ожидание. Деньги появятся в бюджете после подтверждения получения.").font(.footnote).foregroundStyle(.secondary) }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }.navigationTitle(isIncome ? "Новый доход" : "Новый платёж").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Создать") {
                            guard let money else { return }
                            do {
                                if isIncome { try session.createIncome(name: name, amount: money, due: session.calendar.startOfDay(for: due), recurrence: recurrence) }
                                else { try session.createBill(name: name, amount: money, due: session.calendar.startOfDay(for: due), recurrence: recurrence, category: category, reserve: reserve) }
                                dismiss()
                            } catch { errorMessage = "Не удалось сохранить. Проверьте сумму и доступный остаток." }
                        }.disabled(money == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

struct CashPlanCard: View {
    let session: BudgetSession
    var body: some View {
        if let plan = session.cashPlan {
            VStack(alignment: .leading, spacing: 12) {
                Label("До следующего дохода", systemImage: "calendar.badge.clock").font(.headline)
                if let income = plan.nextIncome {
                    Text("\(income.name) · \(income.dueDate.formatted(date: .abbreviated, time: .omitted))").font(.subheadline).foregroundStyle(.secondary)
                    LabeledContent("Ожидается", value: MoneyText.string(income.amount))
                } else { Text("Доход пока не запланирован · горизонт 30 дней").font(.footnote).foregroundStyle(.secondary) }
                LabeledContent("Свободно сейчас", value: MoneyText.string(plan.available))
                LabeledContent("Платежи без резерва", value: MoneyText.string(plan.unreservedPayments))
                Text("≈\(MoneyText.string(plan.dailyGuide)) в день · \(plan.days) дн.").font(.title3.bold()).monospacedDigit()
                if plan.beforeIncome.minorUnits < 0 { Text("Дефицит перед доходом: \(MoneyText.string(plan.beforeIncome)).").foregroundStyle(.red) }
                if plan.nextIncome != nil { LabeledContent("Прогноз после дохода", value: MoneyText.string(plan.afterExpectedIncome)) }
                Text("Прогноз предполагает отсутствие других трат. Зарезервированные платежи уже исключены из свободных денег. Ожидаемый доход доступен после подтверждения.").font(.caption).foregroundStyle(.secondary)
            }.budgetCard()
        }
    }
}

struct SummaryPlanningSection: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var scope = BudgetScope.personal
    @State private var showing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ближайшие платежи").font(.title2.bold())
            ForEach([personal, family], id: \.scope) { session in
                ForEach(Array(session.obligations.filter(\.isPending).prefix(3))) { bill in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bill.name).font(.headline)
                            Text("\(session.scope.title) · \(bill.dueDate.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(MoneyText.string(bill.amount)).monospacedDigit()
                    }.budgetCard()
                }
            }
            HStack {
                Button("Личные планы") { scope = .personal; showing = true }
                Spacer()
                Button("Семейные планы") { scope = .family; showing = true }
            }.buttonStyle(.bordered)
        }.sheet(isPresented: $showing) {
            NavigationStack { BudgetPlansView(session: scope == .personal ? personal : family)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showing = false } } } }
        }
    }
}
