import SwiftUI
import FolkiDuoCore

private enum BudgetSheet: String, Identifiable {
    case setup, expense, contribution, details, settings, limits
    var id: String { rawValue }
}

struct BudgetRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var selectedScope: BudgetScope = .personal
    private var session: BudgetSession { selectedScope == .personal ? personal : family }
    @State private var sheet: BudgetSheet?
    @State private var editingRecord: LedgerRecord?
    @Binding var selectedDay: Date?
    @State private var entryKind: TransactionKind = .expense
    @State private var analyticsJump = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var calendar: Calendar {
        var calendar = family.household?.period.calendar ?? personal.household?.period.calendar ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    var body: some View {
        let date = selectedDay ?? session.referenceDate
        let personalDay = personal.overview(on: date)
        let familyDay = family.overview(on: date)
        let overview = selectedScope == .personal ? personalDay : familyDay
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BudgetWeekCalendar(selection: $selectedDay, today: session.referenceDate, calendar: calendar)
                    Button { sheet = .details } label: {
                        BudgetRingsCard(personal: personalDay.result, family: familyDay.result, isToday: selectedDay == nil, part: .rings)
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                    entryActions
                    Button { sheet = .details } label: {
                        BudgetRingsCard(personal: personalDay.result, family: familyDay.result, isToday: selectedDay == nil, part: .values)
                    }.buttonStyle(.plain)
                    if selectedDay != nil {
                        Text("Итоги дня по текущим записям")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Бюджет", selection: $selectedScope) {
                        ForEach(BudgetScope.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    BudgetAnalyticsSection(session: session, date: date).id("analytics")
                    if let result = overview.result {
                        if selectedDay == nil { forecast(result) }
                        recentRecords(overview.records)
                    } else {
                        ContentUnavailableView {
                            Label(selectedDay == nil ? session.scope.title + " бюджет" : "Нет плана на эту дату", systemImage: "wallet.bifold")
                        } description: {
                            Text(overview.errorMessage ?? (selectedDay != nil ? "Выберите другой день или вернитесь к сегодняшнему бюджету." : selectedScope == .personal ? "Личные расходы и накопления видите только вы. Укажите свой план месяца." : "Здесь общий план пары. Личные деньги участников остаются отдельно."))
                        } actions: {
                            if selectedDay == nil {
                                Button("Настроить бюджет") { sheet = .setup }.buttonStyle(.borderedProminent)
                            } else {
                                Button("Сегодня") { selectedDay = nil }.buttonStyle(.borderedProminent)
                            }
                        }.frame(minHeight: 230)
                    }
                    if selectedDay == nil { SavingsSection(session: session).id(selectedScope) }
                    budgetLinks
                    Text(session.isDemo ? "Демонстрационные данные · 17 октября" : (session.repository?.statusText ?? "Хранилище недоступно"))
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 40)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .top, spacing: 0) {
                header.padding(.horizontal, 20).padding(.vertical, 8)
                    .background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle("Бюджет")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: analyticsJump) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo("analytics", anchor: .top) }
            }
            }
        }
        .sheet(item: $editingRecord) { ExpenseEditorView(session: session, editing: $0) }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .setup: BudgetSetupView(session: session)
            case .expense: ExpenseEditorView(session: session, initialKind: entryKind)
            case .contribution: ContributionView(personal: personal, family: family)
            case .limits: SpendingLimitsView(personal: personal, family: family, scope: selectedScope)
            case .settings: BudgetSettingsView(personal: personal, family: family)
            case .details: BudgetCalculationView(personal: personalDay.result, family: familyDay.result, date: date)
            }
        }
    }

    @ViewBuilder private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                heading
                headerActions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(alignment: .center) {
                heading
                Spacer(minLength: 16)
                headerActions
            }
        }
    }
    private var heading: some View {
        Text("Бюджет").font(.system(.largeTitle, design: .rounded, weight: .bold))
            .lineLimit(1).minimumScaleFactor(0.6).accessibilityAddTraits(.isHeader)
    }
    private var headerActions: some View {
        HStack(spacing: 4) {
            Button { analyticsJump = UUID() } label: {
                Image(systemName: "chart.bar.xaxis").frame(width: 44, height: 44)
            }.accessibilityLabel("Аналитика бюджета")
            Button { sheet = .settings } label: {
                Image(systemName: "gearshape").frame(width: 44, height: 44)
            }.accessibilityLabel("Настройки бюджета")
            Button { sheet = .limits } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }.accessibilityLabel("Лимиты расходов")
        }
        .font(.system(size: 22)).foregroundStyle(Color.folkiAccent).buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .glassEffect(.regular, in: .capsule)
    }

    private var entryActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Menu {
                Button("Личные деньги", systemImage: "person") { openEntry(.personal, kind: .expense) }
                Button("Семейные деньги", systemImage: "person.2") { openEntry(.family, kind: .expense) }
            } label: {
                Label("Потратить", systemImage: "minus.circle").frame(maxWidth: .infinity)
                    .foregroundStyle(colorScheme == .dark ? Color.black : .white)
            }.buttonStyle(.borderedProminent)
            Menu {
                Button("В личный бюджет", systemImage: "person") { openEntry(.personal, kind: .income) }
                Button("В семейный бюджет", systemImage: "person.2") { openEntry(.family, kind: .income) }
                Divider()
                Button("Из личного в семейный", systemImage: "arrow.right.circle") { openContribution() }
            } label: {
                Label("Внести", systemImage: "plus.circle").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
        }.controlSize(.large).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
    }

    private func openEntry(_ scope: BudgetScope, kind: TransactionKind) {
        selectedDay = nil
        selectedScope = scope
        entryKind = kind
        let destination = scope == .personal ? personal : family
        sheet = destination.result == nil ? .setup : .expense
    }

    private func openContribution() {
        selectedDay = nil
        if personal.result == nil { selectedScope = .personal; sheet = .setup }
        else if family.result == nil { selectedScope = .family; sheet = .setup }
        else { sheet = .contribution }
    }

    private func recentRecords(_ records: [LedgerRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Записи за день").font(.title2.bold())
                Spacer()
                NavigationLink("Все") { BudgetHistoryView(session: session).toolbar(.visible, for: .navigationBar) }.font(.subheadline)
            }
            if records.isEmpty {
                Text("В этот день записей нет.")
                    .font(.subheadline).foregroundStyle(.secondary).budgetCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(records.reversed()) { record in
                        if session.isEditable(record) {
                            Button { editingRecord = record } label: {
                                LedgerRow(record: record, payer: session.payerName(for: record))
                            }.buttonStyle(.plain)
                        } else {
                            LedgerRow(record: record, payer: session.payerName(for: record))
                        }
                        if record.id != records.first?.id { Divider() }
                    }
                }.budgetCard()
            }
        }
    }

    private var budgetLinks: some View {
        VStack(spacing: 0) {
            NavigationLink { BudgetHistoryView(session: session).toolbar(.visible, for: .navigationBar) } label: {
                destinationRow("История операций", symbol: "clock.arrow.circlepath")
            }
        }.buttonStyle(.plain).budgetCard()
    }

    private func destinationRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.folkiAccent).frame(width: 24)
            Text(title).font(.body)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }.padding(.vertical, 10)
    }

    private func forecast(_ result: DailyBudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Следующие дни", systemImage: "calendar").font(.headline).foregroundStyle(Color.folkiAccent)
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
    let personal: DailyBudgetSnapshot?
    let family: DailyBudgetSnapshot?
    let date: Date
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(date, format: .dateTime.day().month(.wide).year()) }
                calculation(personal, title: "Личный бюджет")
                calculation(family, title: "Семейный бюджет")
                Section("Кольца снаружи внутрь") {
                    Text("Личный остаток дня, семейный остаток дня, личный остаток месячного лимита, семейный остаток месячного лимита.")
                    Text("Резервы и накопления исключены из свободных денег. Прогноз предполагает, что сегодня больше не будет расходов.")
                }
            }
            .navigationTitle("Личный и семейный").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
    @ViewBuilder private func calculation(_ snapshot: DailyBudgetSnapshot?, title: String) -> some View {
        Section(title) {
            if let result = snapshot {
                LabeledContent("Ориентир дня", value: MoneyText.string(result.todayGuide))
                LabeledContent("Потрачено с учётом возвратов", value: MoneyText.string(result.todayNetSpending))
                LabeledContent("Сегодня осталось", value: MoneyText.string(result.todayRemaining))
                LabeledContent("Месячный лимит", value: MoneyText.string(result.monthlyPlan))
                LabeledContent("Остаток месяца", value: MoneyText.string(result.monthlyRemaining))
            } else { Text("План не настроен или период закончился.").foregroundStyle(.secondary) }
        }
    }
}

struct LedgerRow: View {
    let record: LedgerRecord
    let payer: String
    private var prefix: String {
        switch record.transaction.kind {
        case .expense: "−"
        case .refund, .income: "+"
        case .reserveAllocation, .contributionOut: "↗ "
        case .reserveRelease, .contributionIn: "↙ "
        }
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                Text(([payer] + (record.transaction.kind.isContribution ? [] : [record.category.title])
                    + [record.transaction.date.formatted(.dateTime.day().month())]).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
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
