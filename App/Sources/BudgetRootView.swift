import SwiftUI
import FolkiDuoCore

private enum BudgetSheet: String, Identifiable {
    case setup, expense, details, sharing
    var id: String { rawValue }
}

struct BudgetRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var selectedScope: BudgetScope = .personal
    private var session: BudgetSession { selectedScope == .personal ? personal : family }
    @State private var sheet: BudgetSheet?
    @State private var editingRecord: LedgerRecord?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(session.referenceDate, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Button { sheet = .details } label: {
                        BudgetRingsCard(personal: personal.result, family: family.result)
                    }.buttonStyle(.plain)
                    Picker("Бюджет", selection: $selectedScope) {
                        ForEach(BudgetScope.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if let result = session.result {
                        forecast(result)
                        recentRecords
                    } else {
                        ContentUnavailableView {
                            Label(session.scope.title + " бюджет", systemImage: "wallet.bifold")
                        } description: {
                            Text(session.errorMessage ?? (selectedScope == .personal ? "Личные расходы и накопления видите только вы. Укажите свой план месяца." : "Здесь общий план пары. Личные деньги участников остаются отдельно."))
                        } actions: {
                            Button("Настроить бюджет") { sheet = .setup }.buttonStyle(.borderedProminent)
                        }.frame(minHeight: 230)
                    }
                    SavingsSection(session: session).id(selectedScope)
                    budgetLinks
                    Text(session.isDemo ? "Демонстрационные данные · 17 октября" : (session.repository?.statusText ?? "Хранилище недоступно"))
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }.padding(20).padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Бюджет")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Бюджет и пара", systemImage: "person.2") { sheet = .sharing }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Добавить запись", systemImage: "plus") {
                        Button("Личная запись", systemImage: "person") { openEntry(.personal) }
                        Button("Семейная запись", systemImage: "person.2") { openEntry(.family) }
                    }
                }
            }
        }
        .sheet(item: $editingRecord) { ExpenseEditorView(session: session, editing: $0) }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .setup: BudgetSetupView(session: session)
            case .expense: ExpenseEditorView(session: session)
            case .sharing: SharingView(session: family)
            case .details: BudgetCalculationView(personal: personal, family: family)
            }
        }
    }

    private func openEntry(_ scope: BudgetScope) {
        selectedScope = scope
        let destination = scope == .personal ? personal : family
        sheet = destination.result == nil ? .setup : .expense
    }

    private var recentRecords: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Последние записи").font(.title2.bold())
                Spacer()
                NavigationLink("Все") { BudgetHistoryView(session: session) }.font(.subheadline)
            }
            if session.records.isEmpty {
                Text("Здесь появятся ваши расходы и поступления.")
                    .font(.subheadline).foregroundStyle(.secondary).budgetCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(session.records.suffix(3).reversed()) { record in
                        if session.isEditable(record) {
                            Button { editingRecord = record } label: {
                                LedgerRow(record: record, payer: session.payerName(for: record))
                            }.buttonStyle(.plain)
                        } else {
                            LedgerRow(record: record, payer: session.payerName(for: record))
                        }
                        if record.id != session.records.suffix(3).first?.id { Divider() }
                    }
                }.budgetCard()
            }
        }
    }

    private var budgetLinks: some View {
        VStack(spacing: 0) {
            NavigationLink { BudgetHistoryView(session: session) } label: {
                destinationRow("История операций", symbol: "clock.arrow.circlepath")
            }
            Divider().padding(.leading, 36)
            NavigationLink { BudgetAwardsView() } label: {
                destinationRow("Награды", symbol: "medal")
            }
        }.buttonStyle(.plain).budgetCard()
    }

    private func destinationRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.orange).frame(width: 24)
            Text(title).font(.body)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }.padding(.vertical, 10)
    }

    private func forecast(_ result: DailyBudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Следующие дни", systemImage: "calendar").font(.headline).foregroundStyle(.orange)
            if result.monthlyRemaining.minorUnits < 0 {
                Text("Свободный бюджет закончился").font(.title3.bold())
                Text("Пересмотрите расходы или план.").font(.subheadline).foregroundStyle(.secondary)
            } else if let future = result.futureAllocation {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("≈\(MoneyText.string(future.firstDayAmount))").font(.system(.title, design: .rounded, weight: .bold))
                    Text("в день").font(.subheadline).foregroundStyle(.secondary)
                }.monospacedDigit()
                Text("Если сегодня больше не тратить · \(future.days) дн.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Последний день периода").font(.title3.bold())
                Text("Сегодня доступен оставшийся бюджет.").font(.subheadline).foregroundStyle(.secondary)
            }
        }.budgetCard()
    }
}

private struct BudgetCalculationView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    var body: some View {
        NavigationStack {
            Form {
                calculation(personal)
                calculation(family)
                Section("Кольца снаружи внутрь") {
                    Text("Личный остаток дня, семейный остаток дня, личный остаток месячного лимита, семейный остаток месячного лимита.")
                    Text("Резервы и накопления исключены из свободных денег. Прогноз предполагает, что сегодня больше не будет расходов.")
                }
            }
            .navigationTitle("Личный и семейный").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
    @ViewBuilder private func calculation(_ session: BudgetSession) -> some View {
        Section(session.scope.title + " бюджет") {
            if let result = session.result {
                LabeledContent("Ориентир дня", value: MoneyText.string(result.todayGuide))
                LabeledContent("Потрачено с учётом возвратов", value: MoneyText.string(result.todayNetSpending))
                LabeledContent("Сегодня осталось", value: MoneyText.string(result.todayRemaining))
                LabeledContent("Месячный лимит", value: MoneyText.string(result.monthlyPlan))
                LabeledContent("Остаток месяца", value: MoneyText.string(result.monthlyRemaining))
            } else { Text("План не настроен или период закончился.").foregroundStyle(.secondary) }
        }
    }
}

struct BudgetAwardsView: View {
    var body: some View {
        #if FOLKI_DEMO
        DemoAwardsView()
        #else
        ContentUnavailableView("Ваш прогресс вместе", systemImage: "medal",
            description: Text("Здесь появятся достижения за совместное планирование бюджета."))
            .navigationTitle("Награды")
        #endif
    }
}

struct LedgerRow: View {
    let record: LedgerRecord
    let payer: String
    private var prefix: String {
        switch record.transaction.kind {
        case .expense: "−"
        case .refund, .income: "+"
        case .reserveAllocation: "↗ "
        case .reserveRelease: "↙ "
        }
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                Text("\(payer) · \(record.category.title) · \(record.transaction.date.formatted(.dateTime.day().month()))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("\(prefix)\(MoneyText.string(record.transaction.amount))").monospacedDigit()
        }.font(.subheadline).padding(.vertical, 10)
    }
}

extension View {
    func budgetCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
