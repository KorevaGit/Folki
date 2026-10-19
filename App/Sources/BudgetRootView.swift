import SwiftUI
import FolkiDuoCore

private enum BudgetSheet: String, Identifiable {
    case setup, spend, income, expense, contribution, details, settings, limits
    var id: String { rawValue }
}

struct BudgetRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var showsMonth = false
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
            GeometryReader { page in
                let card = BudgetRingsCard(personal: personalDay.result, family: familyDay.result,
                                           isToday: selectedDay == nil, showsMonth: showsMonth,
                                           togglePeriod: toggleRingPeriod) { scope in
                    selectedScope = scope; sheet = .limits
                }
                if page.size.height < 520 || dynamicTypeSize.isAccessibilitySize {
                    ScrollView {
                        VStack(spacing: FolkiSpacing.card) {
                            weekCalendar
                            if dynamicTypeSize.isAccessibilitySize {
                                interactiveRings(card.rings)
                            } else {
                                interactiveRings(card.rings).aspectRatio(FinancialRings.aspectRatio, contentMode: .fit)
                                    .padding(.horizontal, -8)
                            }
                            entryArea(date: date, personalDay: personalDay, familyDay: familyDay)
                            card.outlook.contentShape(Rectangle()).onTapGesture { sheet = .details }
                        }.folkiPagePadding(top: 4)
                    }.scrollBounceBehavior(.basedOnSize)
                } else {
                    VStack(spacing: FolkiSpacing.card) {
                        weekCalendar.padding(.horizontal, FolkiSpacing.page)
                        ScrollView {
                            BudgetDashboardLayout {
                                interactiveRings(card.rings).padding(.horizontal, -8)
                                entryArea(date: date, personalDay: personalDay, familyDay: familyDay)
                                card.outlook.contentShape(Rectangle()).onTapGesture { sheet = .details }
                            }.padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
                        }.scrollBounceBehavior(.basedOnSize)
                    }.padding(.top, 4)
                        .frame(maxWidth: FolkiSpacing.maxWidth).frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, FolkiSpacing.card)
            .background { FolkiBackground() }
            .navigationTitle("Бюджет")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { headerActions }
            .onAppear { FolkiFeedback.prepare() }
        }
        .sheet(item: $editingRecord) { ExpenseEditorView(session: session, editing: $0) }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .setup: BudgetSetupView(session: session)
            case .spend: QuickSpendView(personal: personal, family: family)
            case .income: QuickSpendView(personal: personal, family: family, entryKind: .income, initialScope: selectedScope)
            case .expense: ExpenseEditorView(session: session, initialKind: entryKind)
            case .contribution: ContributionView(personal: personal, family: family)
            case .limits: SpendingLimitsView(personal: personal, family: family, scope: selectedScope)
            case .settings: BudgetSettingsView(personal: personal, family: family)
            case .details: BudgetCalculationView(personal: personalDay.result, family: familyDay.result, date: date)
            }
        }
    }

    private func toggleRingPeriod() {
        FolkiFeedback.toggle()
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2)) { showsMonth.toggle() }
    }

    private var isAtToday: Bool {
        calendar.isDate(selectedDay ?? session.referenceDate, inSameDayAs: session.referenceDate)
    }

    private func interactiveRings<Content: View>(_ content: Content) -> some View {
        content
            .accessibilityAction(named: Text("Предыдущий день")) { moveDay(-1) }
            .accessibilityAction(named: Text("Следующий день")) { moveDay(1) }
    }

    private func moveDay(_ offset: Int, animated: Bool = true) {
        let today = calendar.startOfDay(for: session.referenceDate)
        let current = calendar.startOfDay(for: selectedDay ?? today)
        guard let target = calendar.date(byAdding: .day, value: offset, to: current) else { return }
        guard target <= today else { FolkiFeedback.boundary(); return }
        FolkiFeedback.selection()
        withAnimation(animated && !reduceMotion ? .snappy(duration: 0.3) : nil) {
            selectedDay = calendar.isDate(target, inSameDayAs: today) ? nil : target
        }
    }

    private var weekCalendar: some View {
        BudgetWeekCalendar(selection: $selectedDay, today: session.referenceDate, calendar: calendar) { day in
            (personal.overview(on: day).result?.dayRingFraction, family.overview(on: day).result?.dayRingFraction)
        }
    }

    private var headerActions: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            NavigationLink {
                ScopedScreen(personal: personal, family: family, title: "Аналитика") {
                    BudgetAnalyticsSection(session: $0, date: selectedDay ?? personal.referenceDate)
                }
            } label: {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(Color.folkiInk).accessibilityLabel("Аналитика")
            }
            Button { sheet = .settings } label: {
                Image(systemName: "gearshape").foregroundStyle(Color.folkiInk).accessibilityLabel("Настройки")
            }
        }
    }

    @ViewBuilder private func entryArea(date: Date, personalDay: BudgetDayOverview, familyDay: BudgetDayOverview) -> some View {
        if selectedDay == nil {
            spendButton.padding(.horizontal, -8)
        } else {
            BudgetDaySpendingSummary(date: date, personal: personal, family: family,
                                     personalDay: personalDay, familyDay: familyDay)
        }
    }

    private var spendButton: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return GlassEffectContainer(spacing: 12) {
        layout {
            Button {
                FolkiFeedback.tap()
                returnToToday {
                    sheet = personal.result == nil && family.result == nil ? .setup : .spend
                }
            } label: {
                Text("− Потратить").frame(maxWidth: .infinity).frame(minHeight: 70)
                    .foregroundStyle(.white)
                    .glassEffect(.regular.tint(Color.folkiAccent).interactive(), in: Capsule())
            }
            .buttonStyle(FolkiPressStyle())
            .frame(minWidth: 104, maxWidth: .infinity)
            Menu {
                Button("Доход в личный", systemImage: "person") { openEntry(.personal, kind: .income) }
                Button("Доход в семейный", systemImage: "person.2") { openEntry(.family, kind: .income) }
                Button("Взнос в семейный", systemImage: "arrow.right.circle") { openContribution() }
            } label: {
                Text("+ Внести").frame(maxWidth: .infinity, minHeight: 70)
                    .glassEffect(.regular.interactive(), in: Capsule()).foregroundStyle(Color.folkiInk)
            }
            .menuStyle(.button).buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { FolkiFeedback.tap(); returnToToday() })
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 140)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        }
        .font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.8).buttonStyle(.plain)
        }
    }

    private func returnToToday(then action: @escaping () -> Void = {}) {
        guard selectedDay != nil else { action(); return }
        if reduceMotion {
            selectedDay = nil
            action()
        } else {
            withAnimation(.smooth(duration: 0.35), completionCriteria: .logicallyComplete) {
                selectedDay = nil
            } completion: {
                action()
            }
        }
    }

    private func openEntry(_ scope: BudgetScope, kind: TransactionKind) {
        returnToToday {
            selectedScope = scope
            entryKind = kind
            let destination = scope == .personal ? personal : family
            sheet = destination.result == nil ? .setup : (kind == .income ? .income : .expense)
        }
    }

    private func openContribution() {
        returnToToday {
            if personal.result == nil { selectedScope = .personal; sheet = .setup }
            else if family.result == nil { selectedScope = .family; sheet = .setup }
            else { sheet = .contribution }
        }
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
            .folkiFormLayout()
            .navigationTitle("Личный и семейный").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
    @ViewBuilder private func calculation(_ snapshot: DailyBudgetSnapshot?, title: String) -> some View {
        Section(title) {
            if let result = snapshot {
                LabeledContent("Ориентир дня", value: MoneyText.whole(result.todayGuide))
                LabeledContent("Потрачено с учётом возвратов", value: MoneyText.whole(result.todayNetSpending))
                LabeledContent("Сегодня осталось", value: MoneyText.whole(result.todayRemaining))
                LabeledContent("Месячный лимит", value: MoneyText.whole(result.monthlyPlan))
                LabeledContent("Остаток месяца", value: MoneyText.whole(result.monthlyRemaining))
            } else { Text("План не настроен или период закончился.").foregroundStyle(.secondary) }
        }
    }
}

struct LedgerRow: View {
    let record: LedgerRecord
    let session: BudgetSession
    /// History groups rows by day, so the date there would repeat the section header.
    var showsDate = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var kindTitle: String {
        switch record.transaction.kind {
        case .expense: "Трата"; case .refund: "Возврат"; case .income: "Поступление"
        case .reserveAllocation: "В накопления"; case .reserveRelease: "Из накоплений"
        case .contributionOut: "Взнос в семейный"; case .contributionIn: "Взнос участника"
        }
    }

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
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if let category {
                CategoryIcon(category: category)
            } else {
                CategoryIcon(symbol: record.transaction.kind.isContribution ? "person.2.fill" : "arrow.left.arrow.right", color: .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title.isEmpty ? (category?.name ?? "") : record.title)
                Text(([session.payerName(for: record)] + (category.map { [$0.name] } ?? [])
                    + (showsDate ? [record.transaction.date.formatted(.dateTime.day().month())] : [])).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("\(prefix)\(MoneyText.string(record.transaction.amount))").monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65).layoutPriority(1)
        }.font(.subheadline).padding(.vertical, 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([kindTitle, record.title.isEmpty ? category?.name ?? "Другое" : record.title,
                session.payerName(for: record), record.transaction.date.formatted(.dateTime.day().month(.wide).year()),
                record.transaction.isDeleted ? "Удалённая запись" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityValue(MoneyText.string(record.transaction.amount))
    }
}

extension View {
    func budgetCard() -> some View {
        padding(FolkiSpacing.card).frame(maxWidth: .infinity, alignment: .leading)
            .folkiGlass(RoundedRectangle(cornerRadius: 20))
    }
}

/// Keep the ring diameter stable when entry actions become a past-day recap.
/// Additional content scrolls within the safe area above the native tab bar.
private struct BudgetDashboardLayout: Layout {
    private let spacing: CGFloat = 20

    private func metrics(width: CGFloat, subviews: Subviews) -> (heights: [CGFloat], total: CGFloat) {
        var heights = subviews.enumerated().map { index, view in
            index == 0 ? CGFloat.zero : view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        // Match the wider action row and preserve true circles.
        // Short screens can scroll instead of distorting the rings.
        heights[0] = (width + 16) / FinancialRings.aspectRatio
        return (heights, heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 350
        return CGSize(width: width, height: metrics(width: width, subviews: subviews).total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = metrics(width: bounds.width, subviews: subviews).heights
        var y = bounds.minY
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: heights[index]))
            y += heights[index] + spacing
        }
    }
}

/// A read-only spending recap replaces today's entry actions when browsing the past.
private struct BudgetDaySpendingSummary: View {
    let date: Date
    let personal: BudgetSession
    let family: BudgetSession
    let personalDay: BudgetDayOverview
    let familyDay: BudgetDayOverview
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.item) {
            Text("Траты за \(date.formatted(.dateTime.day().month(.wide)))").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                     count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                      alignment: .leading, spacing: FolkiSpacing.card) {
                summary(personal, overview: personalDay)
                summary(family, overview: familyDay)
            }
            Text("С учётом возвратов. Взносы и накопления не входят в траты.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ session: BudgetSession, overview: BudgetDayOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.scope.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.budget(session.scope))
            if overview.errorMessage != nil {
                Text("Не удалось загрузить").font(.footnote).foregroundStyle(.secondary)
            } else if overview.result == nil && overview.records.isEmpty {
                Text("Нет плана на этот день").font(.footnote).foregroundStyle(.secondary)
            } else if let result = try? BudgetAnalytics.calculate(records: overview.records, period: .day,
                anchor: date, asOf: session.referenceDate, calendar: session.calendar, catalog: session.catalog),
                let spent = try? result.netSpending {
                Text(MoneyText.whole(spent)).font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                let count = overview.records.filter { $0.transaction.kind == .expense }.count
                Text("Трат: \(count)").font(.caption).foregroundStyle(.secondary)
                if result.refunds.minorUnits > 0 {
                    Text("Возвраты: \(MoneyText.whole(result.refunds))").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Не удалось посчитать").font(.footnote).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}
