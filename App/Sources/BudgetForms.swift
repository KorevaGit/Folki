import SwiftUI
import FolkiDuoCore

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
    @State private var categoryID: UUID
    @State private var assignIncome: Bool
    @State private var reserveID: UUID?
    @State private var errorMessage: String?
    @State private var choosingCategory = false

    init(session: BudgetSession, editing: LedgerRecord? = nil, initialKind: TransactionKind = .expense) {
        self.session = session; self.editing = editing
        _amount = State(initialValue: editing.map { MoneyText.input($0.transaction.amount) } ?? "")
        _title = State(initialValue: editing?.title ?? "")
        _payerID = State(initialValue: editing?.transaction.payerID ?? session.authorID ?? session.members.first?.id ?? UUID())
        _date = State(initialValue: editing?.transaction.date ?? session.referenceDate)
        let type = editing?.transaction.kind ?? initialKind
        _kind = State(initialValue: type == .refund ? "refund" : type == .income ? "income" : "expense")
        _categoryID = State(initialValue: editing?.categoryID ?? BuiltInCategory.other.id)
        _assignIncome = State(initialValue: editing.map { $0.transaction.kind == .income && $0.transaction.funding == .flexible }
            ?? (initialKind == .income))
        if case .reserve(let id) = editing?.transaction.funding { _reserveID = State(initialValue: id) }
        else { _reserveID = State(initialValue: nil) }
    }
    private var draft: LedgerRecord? {
        guard let money = try? MoneyText.parse(amount),
              money.minorUnits > 0 else { return nil }
        let type: TransactionKind = kind == "refund" ? .refund : kind == "income" ? .income : .expense
        let funding: BudgetFunding = type == .income ? (assignIncome ? .flexible : .unallocated)
            : reserveID.map { .reserve($0) } ?? .flexible
        return try? session.draft(amount: money, title: title, payerID: payerID, date: date,
            kind: type, categoryID: categoryID, funding: funding, editing: editing, newRecordID: newRecordID)
    }
    private var editingBudget: StoredBudget? { try? session.budget(editing: editing) }
    private var expenseReserves: [ProtectedReserve] {
        (editingBudget?.snapshot.reserves ?? []).filter { $0.isRegularPayment || $0.id == reserveID }
    }
    private var impact: DailyBudgetSnapshot? { draft.flatMap { try? session.preview($0, editing: editing) } }
    var body: some View {
        NavigationStack {
            Form {
                // The amount leads, like on the spend screen.
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        TextField("0", text: $amount).keyboardType(.decimalPad)
                            .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                            .multilineTextAlignment(.trailing).fixedSize()
                        Text(MoneyText.symbol).font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(amount.isEmpty ? .tertiary : .primary)
                    }.frame(maxWidth: .infinity)

                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                Section {
                    TextField("Описание · необязательно", text: $title)
                    Button { choosingCategory = true } label: {
                        HStack(spacing: 10) {
                            Text("Категория").foregroundStyle(Color.folkiInk)
                            Spacer()
                            let category = session.catalog.category(for: categoryID)
                            CategoryIcon(category: category, size: 24)
                            Text(category.name).foregroundStyle(Color(uiColor: .secondaryLabel))
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                        }
                    }
                    LabeledContent("Бюджет", value: session.scope.title)
                    Picker(kind == "expense" ? String(localized: "Оплатил") : String(localized: "Получил"), selection: $payerID) {
                        ForEach(session.members.filter { $0.isActive || $0.id == editing?.transaction.payerID }) { Text(session.memberName($0.id)).tag($0.id) }
                    }
                    if let budget = editingBudget {
                        let period = budget.snapshot.period
                        DatePicker("Дата", selection: $date, in: period.start...session.calculationDate(in: budget), displayedComponents: .date)
                    }
                    if kind == "income" {
                        Toggle("Добавить в свободный план", isOn: $assignIncome)
                        Text(assignIncome ? String(localized: "Поступление увеличит доступные деньги.") : String(localized: "Поступление будет записано отдельно и не увеличит свободный бюджет."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !expenseReserves.isEmpty {
                        Picker("Источник", selection: $reserveID) {
                            Text("Свободные деньги").tag(nil as UUID?)
                            ForEach(expenseReserves) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
                if let impact, let before = session.result, editing == nil {
                    Section("После сохранения") {
                        ImpactLines(before: before, after: impact).frame(maxWidth: .infinity)
                    }
                } else if !amount.isEmpty && impact == nil {
                    Text("Что-то не сходится — проверь сумму и дату 🙏").foregroundStyle(.secondary)
                }
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                if let editing, session.isEditable(editing), !editing.transaction.isDeleted {
                    Section {
                        Button("Удалить запись", role: .destructive) {
                            do { try session.setDeleted(true, record: editing); FolkiFeedback.saved(); dismiss() }
                            catch { errorMessage = String(localized: "Не получилось удалить. Попробуй снова.") }
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
            .folkiFormLayout()
            .sheet(isPresented: $choosingCategory) {
                CategoryPickerView(session: session, selection: Binding(get: { categoryID }, set: { categoryID = $0 ?? BuiltInCategory.other.id }))
            }
            .navigationTitle(editing == nil ? String(localized: "Новая запись") : String(localized: "Запись")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard let draft else { return }
                        let crossed = kind == "expense" && FolkiFeedback.crossesIntoMinus(before: session.result?.todayRemaining, after: impact?.todayRemaining)
                        do { try session.save(draft, editing: editing); FolkiFeedback.saved(crossedIntoMinus: crossed); dismiss() }
                        catch LedgerError.conflict { errorMessage = String(localized: "Запись уже изменена. Закрой форму и открой её заново.") }
                        catch { errorMessage = String(localized: "Не получилось сохранить. Данные формы остались здесь; попробуй снова.") }
                    }.disabled(impact == nil)
                }
            }
        }
    }
}
