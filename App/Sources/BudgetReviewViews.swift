import SwiftUI
import FolkiDuoCore

struct SpendingReviewCard: View {
    let session: BudgetSession
    let date: Date
    var period: AnalyticsPeriod = .week
    var body: some View {
        if let comparison = try? BudgetAnalytics.comparison(records: session.historyRecords, period: period, anchor: date,
            asOf: session.referenceDate, calendar: session.calendar), let change = try? comparison.change,
           let current = try? comparison.current.netSpending, let previous = try? comparison.previous.netSpending {
            VStack(alignment: .leading, spacing: 10) {
                Text(period == .week ? "Обзор недели · \(session.scope.title.lowercased())" : "Сравнение месяца").font(.headline)
                Text(MoneyText.string(current)).font(.title2.bold()).monospacedDigit()
                Text("Предыдущий сопоставимый период: \(MoneyText.string(previous))").font(.subheadline).foregroundStyle(.secondary)
                Text("Изменение: \(change.minorUnits > 0 ? "+" : "")\(MoneyText.string(change))").font(.subheadline)
                ForEach(Array(comparison.current.categories.prefix(3))) { item in
                    HStack { Label(item.category.title, systemImage: item.category.symbol); Spacer(); Text(MoneyText.string(item.expenses)) }.font(.subheadline)
                }
                Text("Сравнение по \(comparison.current.cutoff.formatted(date: .abbreviated, time: .shortened)) и \(comparison.previous.cutoff.formatted(date: .abbreviated, time: .shortened)). Одинаковые прошедшие дни и время; короткий месяц ограничивает оба периода. Возвраты учтены, переводы исключены.").font(.caption).foregroundStyle(.secondary)
            }.budgetCard()
        }
    }
}

struct CategoryLimitsStatus: View {
    let session: BudgetSession
    let date: Date
    var body: some View {
        if !session.categoryLimits.isEmpty,
           let month = try? BudgetAnalytics.calculate(records: session.historyRecords, period: .month, anchor: date, asOf: session.referenceDate, calendar: session.calendar) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Мягкие лимиты категорий").font(.headline)
                ForEach(session.categoryLimits) { limit in
                    let category = month.categories.first { $0.category == limit.category }
                    let spent = (category?.expenses.minorUnits ?? 0) - (category?.refunds.minorUnits ?? 0)
                    let warning = limit.amount.minorUnits - limit.amount.minorUnits / 5
                    VStack(alignment: .leading, spacing: 5) {
                        Text(limit.category.title).font(.subheadline.bold())
                        Text("\(MoneyText.string(Money(minorUnits: spent))) из \(MoneyText.string(limit.amount))").monospacedDigit()
                        ProgressView(value: max(0, min(1, Double(spent) / Double(limit.amount.minorUnits))))
                            .tint(spent >= limit.amount.minorUnits ? .red : spent >= warning ? .orange : Color.folkiAccent)
                        if spent >= warning { Text(spent >= limit.amount.minorUnits ? "Лимит достигнут · новые расходы разрешены" : "Использовано не менее 80% лимита").font(.caption).foregroundStyle(spent >= limit.amount.minorUnits ? .red : .orange) }
                    }
                }
            }.budgetCard()
        }
    }
}

struct CategoryLimitsView: View {
    let session: BudgetSession
    @State private var category = ExpenseCategory.groceries
    @State private var amount = ""
    @State private var expected: CategoryLimitSnapshot?
    @State private var errorMessage: String?
    var body: some View {
        Form {
            Section("Ежемесячный лимит · \(session.scope.title)") {
                Picker("Категория", selection: $category) { ForEach(ExpenseCategory.allCases, id: \.self) { Text($0.title).tag($0) } }
                TextField("Лимит, \(CurrencyDisplay.shared.symbol)", text: $amount).keyboardType(.decimalPad)
                Button("Сохранить лимит") { save(remove: false) }
                    .disabled((try? MoneyText.parse(amount).minorUnits) ?? 0 <= 0 || session.result == nil)
                if expected != nil { Button("Убрать лимит", role: .destructive) { save(remove: true) } }
                Text("Предупреждения в приложении появляются при пересечении 80% и 100%. Превышение не блокирует запись. Лимит повторяется каждый месяц; учитываются расходы категории за вычетом возвратов, включая оплаты из резервов.").font(.footnote).foregroundStyle(.secondary)
            }
            CategoryLimitsStatus(session: session, date: session.referenceDate).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }.navigationTitle("Категории").navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: reload).onChange(of: category) { reload() }
    }
    private func reload() {
        expected = session.categoryLimits.first { $0.category == category }
        amount = expected.map { MoneyText.input($0.amount) } ?? ""
        errorMessage = nil
    }
    private func save(remove: Bool) {
        do { try session.setCategoryLimit(category, amount: remove ? nil : MoneyText.parse(amount, preserving: expected?.amount), expected: expected); reload() }
        catch { errorMessage = "Лимит не сохранён. Проверьте сумму; при одновременной правке откройте экран заново." }
    }
}

struct IncomeSavingsSuggestions: View {
    let session: BudgetSession
    @State private var selected: SavingsGoalSnapshot?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Доход получен · можно пополнить цели").font(.headline)
            Text("Выберите взнос самостоятельно. Перед сохранением увидите свободный остаток.").font(.footnote).foregroundStyle(.secondary)
            ForEach(session.goals.filter { $0.balance.minorUnits < $0.target.minorUnits }) { goal in
                Button {
                    selected = goal
                } label: {
                    HStack {
                        Text(goal.name)
                        Spacer()
                        if let suggestion = try? BudgetPlanning.suggestedContribution(goal: goal, asOf: session.referenceDate, calendar: session.calendar) {
                            Text(MoneyText.string(suggestion))
                        }
                    }
                }
            }
            if session.goals.isEmpty { Text("Создайте цель в разделе накоплений.").font(.subheadline) }
            Button("Позже") { session.incomeJustReceived = false }.font(.caption)
        }.sheet(item: $selected) { goal in
            GoalTransferView(session: session, goal: goal, initialAmount: (try? BudgetPlanning.suggestedContribution(goal: goal, asOf: session.referenceDate, calendar: session.calendar)))
        }
    }
}
