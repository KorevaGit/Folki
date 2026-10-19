import SwiftUI
import FolkiDuoCore

struct BudgetSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    @State private var monthly = ""
    @State private var available = ""
    @State private var reserveName = ""
    @State private var reserveAmount = ""
    private var reserve: ProtectedReserve? {
        guard let amount = try? MoneyText.parse(reserveAmount), amount.minorUnits > 0, !reserveName.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return ProtectedReserve(name: reserveName, openingAmount: amount)
    }
    @State private var errorMessage: String?
    private var validated: (Money, Money)? {
        guard let plan = try? MoneyText.parse(monthly), plan.minorUnits > 0,
              let funds = try? MoneyText.parse(available), funds.minorUnits >= 0,
              reserveAmount.isEmpty || (reserve != nil && reserve!.openingAmount.minorUnits <= funds.minorUnits) else { return nil }
        return (plan, funds)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("План на месяц", text: $monthly).keyboardType(.decimalPad)
                    TextField("Всего денег, включая накопления", text: $available).keyboardType(.decimalPad)
                } header: { Text("Свободный бюджет, \(CurrencyDisplay.shared.symbol)") } footer: {
                    Text("Укажите все деньги выбранного бюджета, включая накопления. Накопления и резерв будут исключены из свободного остатка. Уже созданный месяц нельзя заменить: исправляйте отдельные операции.")
                }
                Section("Защищённый резерв · необязательно") {
                    TextField("Например, аренда", text: $reserveName)
                    TextField("Сумма резерва, \(CurrencyDisplay.shared.symbol)", text: $reserveAmount).keyboardType(.decimalPad)
                    Text("При оплате из резерва свободные деньги не уменьшатся повторно.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text(session.isDemo ? "Демонстрация: изменения останутся только до закрытия." : session.scope == .personal ? "Личные расходы и накопления видите только вы." : "Семейные расходы и накопления доступны участникам общего пространства.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(session.scope.title + " бюджет").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        guard let values = validated else { return }
                        do { try session.createPlan(monthlyPlan: values.0, available: values.1, reserves: reserve.map { [$0] } ?? []); dismiss() }
                        catch LedgerError.existingPeriod { errorMessage = "План этого месяца уже существует." }
                        catch { errorMessage = "Не удалось сохранить план. Проверьте суммы и доступ к хранилищу." }
                    }.disabled(validated == nil)
                }
            }
        }
    }
}

struct ExpenseEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    let editing: LedgerRecord?
    @State private var newRecordID = UUID()
    @State private var amount: String
    @State private var title: String
    @State private var payerID: UUID
    @State private var date: Date
    @State private var kind: String
    @State private var category: ExpenseCategory
    @State private var assignIncome: Bool
    @State private var reserveID: UUID?
    @State private var errorMessage: String?

    init(session: BudgetSession, editing: LedgerRecord? = nil, initialKind: TransactionKind = .expense) {
        self.session = session; self.editing = editing
        _amount = State(initialValue: editing.map { MoneyText.input($0.transaction.amount) } ?? "")
        _title = State(initialValue: editing?.title ?? "")
        _payerID = State(initialValue: editing?.transaction.payerID ?? session.authorID ?? session.members.first?.id ?? UUID())
        _date = State(initialValue: editing?.transaction.date ?? session.referenceDate)
        let type = editing?.transaction.kind ?? initialKind
        _kind = State(initialValue: type == .refund ? "refund" : type == .income ? "income" : "expense")
        _category = State(initialValue: editing?.category ?? .other)
        _assignIncome = State(initialValue: editing.map { $0.transaction.kind == .income && $0.transaction.funding == .flexible }
            ?? (initialKind == .income))
        if case .reserve(let id) = editing?.transaction.funding { _reserveID = State(initialValue: id) }
        else { _reserveID = State(initialValue: nil) }
    }
    private var draft: LedgerRecord? {
        // Keep the exact original amount when only editing text/category/date.
        guard let money = try? MoneyText.parse(amount, preserving: editing?.transaction.amount),
              money.minorUnits > 0 else { return nil }
        let type: TransactionKind = kind == "refund" ? .refund : kind == "income" ? .income : .expense
        let funding: BudgetFunding = type == .income ? (assignIncome ? .flexible : .unallocated)
            : reserveID.map { .reserve($0) } ?? .flexible
        return try? session.draft(amount: money, title: title, payerID: payerID, date: date,
            kind: type, category: category, funding: funding, editing: editing, newRecordID: newRecordID)
    }
    private var editingBudget: StoredBudget? { try? session.budget(editing: editing) }
    private var expenseReserves: [ProtectedReserve] {
        (editingBudget?.snapshot.reserves ?? []).filter { reserve in !session.goals.contains(where: { $0.id == reserve.id }) }
    }
    private var impact: DailyBudgetSnapshot? { draft.flatMap { try? session.preview($0, editing: editing) } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Бюджет", value: session.scope.title)
                    Picker("Операция", selection: $kind) {
                        Text("Расход").tag("expense"); Text("Возврат").tag("refund"); Text("Поступление").tag("income")
                    }
                    TextField("Сумма, \(CurrencyDisplay.shared.symbol)", text: $amount).keyboardType(.decimalPad).font(.largeTitle.bold())
                    TextField("Описание", text: $title)
                    Picker("Категория", selection: $category) {
                        ForEach(ExpenseCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker(kind == "expense" ? "Оплатил" : "Получил", selection: $payerID) {
                        ForEach(session.members.filter { $0.isActive || $0.id == editing?.transaction.payerID }) { Text(session.memberName($0.id)).tag($0.id) }
                    }
                    if let budget = editingBudget {
                        let period = budget.snapshot.period
                        DatePicker("Дата", selection: $date, in: period.start...session.calculationDate(in: budget), displayedComponents: .date)
                    }
                    if kind == "income" {
                        Toggle("Добавить в свободный план", isOn: $assignIncome)
                        Text(assignIncome ? "Поступление увеличит доступные деньги." : "Поступление будет записано отдельно и не увеличит свободный бюджет.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !expenseReserves.isEmpty {
                        Picker("Источник", selection: $reserveID) {
                            Text("Свободные деньги").tag(nil as UUID?)
                            ForEach(expenseReserves) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
                if let impact {
                    Section("После сохранения") {
                        LabeledContent("Остаток дня") {
                            Text(MoneyText.string(impact.todayRemaining)).foregroundStyle(impact.todayRemaining.minorUnits < 0 ? Color.red : .primary)
                        }
                        LabeledContent("Месяц", value: MoneyText.string(impact.monthlyRemaining))
                        if let future = impact.futureAllocation {
                            LabeledContent("Далее в день", value: "≈\(MoneyText.string(future.firstDayAmount))")
                        }
                        if impact.todayRemaining.minorUnits < 0 {
                            Text("Дневной ориентир будет превышен.").foregroundStyle(.secondary)
                        }
                    }
                } else if !amount.isEmpty {
                    Text("Проверьте сумму, описание, дату и доступный резерв.").foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(editing == nil ? "Новая запись" : "Запись").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard let draft else { return }
                        do { try session.save(draft, editing: editing); dismiss() }
                        catch LedgerError.conflict { errorMessage = "Запись уже изменена. Закройте форму и откройте её заново." }
                        catch { errorMessage = "Не удалось сохранить. Данные формы остались здесь; попробуйте снова." }
                    }.disabled(impact == nil)
                }
            }
        }
    }
}
