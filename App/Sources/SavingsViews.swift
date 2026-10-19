import SwiftUI
import FolkiDuoCore

struct SavingsSection: View {
    let session: BudgetSession
    @State private var creating = false
    @State private var selected: SavingsGoalSnapshot?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(session.scope.savingsTitle).font(.title2.bold())
                Spacer()
                Button("Добавить цель", systemImage: "plus.circle") { creating = true }
                    .labelStyle(.iconOnly).disabled(session.result == nil || session.isDemo)
            }
            if session.goals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(session.scope == .personal ? "На то, что важно тебе" : "На общие планы семьи", systemImage: "flag")
                        .font(.headline)
                    Text("Деньги в накоплениях защищены от повседневных трат.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if session.result != nil && !session.isDemo {
                        Button("Создать цель") { creating = true }.font(.subheadline.weight(.semibold))
                    }
                }.budgetCard()
            } else {
                ForEach(session.goals) { goal in
                    Button { selected = goal } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(goal.name, systemImage: "flag.fill").font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(MoneyText.whole(goal.balance)).font(.title2.bold()).monospacedDigit().fixedSize()
                                    Text("из \(MoneyText.whole(goal.target))").font(.caption).foregroundStyle(.secondary).fixedSize()
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(MoneyText.whole(goal.balance)).font(.title2.bold()).monospacedDigit()
                                        .lineLimit(1).minimumScaleFactor(0.5)
                                    Text("из \(MoneyText.whole(goal.target))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ProgressView(value: goal.fraction).tint(Color.budget(session.scope))
                        }.budgetCard()
                    }.buttonStyle(.plain).disabled(session.result == nil)
                }
            }
        }
        .sheet(isPresented: $creating) { GoalSetupView(session: session) }
        .sheet(item: $selected) { GoalTransferView(session: session, goal: $0) }
    }
}

private struct GoalSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    @State private var name = ""
    @State private var target = ""
    @State private var errorMessage: String?
    private var money: Money? {
        guard let money = try? MoneyText.parse(target), money.minorUnits > 0 else { return nil }
        return money
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(session.scope.savingsTitle) {
                    TextField("На что копим", text: $name)
                    TextField("Цель, \(MoneyText.symbol)", text: $target).keyboardType(.decimalPad)
                    Text(session.scope == .personal ? "Эту цель видишь только ты." : "Эта цель относится к семейному бюджету.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }
            .folkiFormLayout()
            .navigationTitle("Новая цель").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        guard let money else { return }
                        do { try session.createGoal(name: name, target: money); FolkiFeedback.saved(); dismiss() }
                        catch { errorMessage = "Не удалось создать цель. Данные формы сохранены здесь." }
                    }.disabled(money == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct GoalTransferView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    let goal: SavingsGoalSnapshot
    @State private var operationID = UUID()
    @State private var amount = ""
    @State private var withdrawal = false
    @State private var errorMessage: String?
    private var money: Money? {
        guard let money = try? MoneyText.parse(amount), money.minorUnits > 0,
              money.minorUnits <= (withdrawal ? goal.balance.minorUnits : session.result?.monthlyRemaining.minorUnits ?? 0) else { return nil }
        return money
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(goal.name) {
                    LabeledContent("Накоплено", value: MoneyText.whole(goal.balance))
                    LabeledContent("Цель", value: MoneyText.whole(goal.target))
                }
                Section(session.scope.title + " бюджет") {
                    Picker("Действие", selection: $withdrawal) {
                        Text("Пополнить").tag(false)
                        Text("Вернуть в бюджет").tag(true)
                    }
                    TextField("Сумма, \(MoneyText.symbol)", text: $amount).keyboardType(.decimalPad)
                    if let money, let available = session.result?.monthlyRemaining,
                       let free = try? (withdrawal ? available.adding(money) : available.subtracting(money)),
                       let saved = try? (withdrawal ? goal.balance.subtracting(money) : goal.balance.adding(money)) {
                        LabeledContent("Останется свободно", value: MoneyText.whole(free))
                        LabeledContent("В накоплениях", value: MoneyText.whole(saved))
                        if let before = session.result,
                           let after = session.previewTransfer(money, kind: withdrawal ? .reserveRelease : .reserveAllocation, funding: .reserve(goal.id)) {
                            ImpactLines(before: before, after: after).frame(maxWidth: .infinity)
                        }
                    }
                    Text("Это перевод между свободными деньгами и накоплениями внутри выбранного бюджета.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }
            .folkiFormLayout()
            .navigationTitle("Накопления").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard let money else { return }
                        do { try session.transfer(goal: goal, amount: money, withdrawal: withdrawal, operationID: operationID); FolkiFeedback.saved(); dismiss() }
                        catch { errorMessage = "Не удалось перевести деньги. Проверь остаток и повтори." }
                    }.disabled(money == nil)
                }
            }
        }
    }
}
