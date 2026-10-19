import SwiftUI
import FolkiDuoCore

private enum BudgetSheet: String, Identifiable {
    case setup, spend, expense, contribution, details, settings, limits
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header.padding(.top, 8)
                    BudgetWeekCalendar(selection: $selectedDay, today: session.referenceDate, calendar: calendar) { day in
                        (personal.overview(on: day).result?.dayRingFraction, family.overview(on: day).result?.dayRingFraction)
                    }
                    BudgetRingsCard(personal: personalDay.result, family: familyDay.result, isToday: selectedDay == nil) { scope in
                        selectedScope = scope; sheet = .limits
                    }
                    .contentShape(Rectangle()).onTapGesture { sheet = .details }
                    spendButton
                    if selectedDay != nil {
                        Text("Итоги дня по текущим записям")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    SummaryCards(personal: personal, family: family, date: date).padding(.top, 8)
                    Text(session.isDemo ? "Демонстрационные данные · 17 октября" : (session.repository?.statusText ?? "Хранилище недоступно"))
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 40)
            }
            .background { FolkiBackground() }
            .navigationTitle("Бюджет")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $editingRecord) { ExpenseEditorView(session: session, editing: $0) }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .setup: BudgetSetupView(session: session)
            case .spend: QuickSpendView(personal: personal, family: family)
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
        VStack(alignment: .leading, spacing: 0) {
            Text(personal.referenceDate, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text("Бюджет").font(.system(.largeTitle, design: .rounded, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.6).accessibilityAddTraits(.isHeader)
        }
    }
    private var headerActions: some View {
        HStack(spacing: 4) {
            NavigationLink {
                ScopedScreen(personal: personal, family: family, title: "Аналитика") { BudgetAnalyticsSection(session: $0, date: selectedDay ?? personal.referenceDate) }
            } label: {
                Image(systemName: "chart.bar.xaxis").frame(width: 44, height: 44)
            }.accessibilityLabel("Аналитика")
            Button { sheet = .settings } label: {
                Image(systemName: "gearshape").frame(width: 44, height: 44)
            }.accessibilityLabel("Настройки")
        }
        .font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.folkiInk).buttonStyle(.plain)
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }

    private var spendButton: some View {
        HStack(spacing: 10) {
            Button {
                selectedDay = nil
                sheet = personal.result == nil && family.result == nil ? .setup : .spend
            } label: {
                Text("− Потратить").frame(maxWidth: .infinity).frame(height: 64)
                    .background(Color.folkiAccent, in: Capsule()).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity).layoutPriority(2)
            Menu {
                Button("Поступление в личный", systemImage: "person") { openEntry(.personal, kind: .income) }
                Button("Поступление в семейный", systemImage: "person.2") { openEntry(.family, kind: .income) }
                Button("Взнос из личного в семейный", systemImage: "arrow.right.circle") { openContribution() }
            } label: {
                Text("+ Внести").frame(width: 132, height: 64)
                    .folkiGlass(Capsule()).foregroundStyle(Color.folkiInk)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
        }
        .font(.system(.title3, design: .rounded, weight: .bold)).buttonStyle(.plain)
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

    private func destinationRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.folkiAccent).frame(width: 24)
            Text(title).font(.body)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }.padding(.vertical, 10)
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
                Section("Кольца") {
                    Text("Снаружи — личный остаток дня, внутри — семейный. Кольцо пустеет по мере трат и становится пустым при перерасходе.")
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
    let session: BudgetSession
    private var prefix: String {
        switch record.transaction.kind {
        case .expense: "−"
        case .refund, .income: "+"
        case .reserveAllocation, .contributionOut: "↗ "
        case .reserveRelease, .contributionIn: "↙ "
        }
    }
    var body: some View {
        let category = session.category(for: record)
        HStack(spacing: 12) {
            if let category {
                CategoryIcon(category: category)
            } else {
                CategoryIcon(symbol: record.transaction.kind.isContribution ? "person.2.fill" : "arrow.left.arrow.right", color: .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title.isEmpty ? (category?.name ?? "") : record.title)
                Text(([session.payerName(for: record)] + (category.map { [$0.name] } ?? [])
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
            .folkiGlass(RoundedRectangle(cornerRadius: 20))
    }
}
