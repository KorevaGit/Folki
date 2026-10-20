import SwiftUI
import FolkiDuoCore

private enum BudgetSheet: String, Identifiable {
    case setup, spend, income, expense, contribution, details, settings, limits, distribution, envelopes
    var id: String { rawValue }
}

struct BudgetRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var showsMonth = false
    @State private var showingDayHistory = false
    @State private var pageDrag: CGFloat = 0
    @State private var historyAtTop = true
    @State private var paging = false
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
            GeometryReader { _ in
                let card = BudgetRingsCard(personal: personalDay.result, family: familyDay.result,
                                           isToday: selectedDay == nil, showsMonth: showsMonth,
                                           togglePeriod: toggleRingPeriod,
                                           showsFamily: family.household != nil,
                                           personalNeedsFunds: !personal.hasFunding, familyNeedsFunds: !family.hasFunding,
                                           addFunds: { scope in selectedScope = scope; sheet = .income }) { scope in
                    selectedScope = scope; sheet = .limits
                }
                VStack(spacing: 8) {
                    weekCalendar.padding(.horizontal, FolkiSpacing.page)
                    GeometryReader { viewport in
                        let height = viewport.size.height
                        ZStack(alignment: .top) {
                            VStack(spacing: 12) {
                                interactiveRings(card.rings).frame(maxHeight: .infinity)
                                entryArea(date: date, personalDay: personalDay, familyDay: familyDay)
                                distributionLine
                                Button { showHistory(true) } label: {
                                    Label("Траты за день", systemImage: "chevron.down")
                                        .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40)
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, FolkiSpacing.page)
                            .frame(width: viewport.size.width, height: height)
                            .offset(y: (showingDayHistory ? -height : 0) + pageDrag)
                            .allowsHitTesting(!showingDayHistory && !paging).accessibilityHidden(showingDayHistory)

                            VStack(spacing: 8) {
                                Button { showHistory(false) } label: {
                                    Label("К кольцу", systemImage: "chevron.up")
                                        .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40)
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                                DailyExpenseHistoryView(personal: personal, family: family,
                                    personalDay: personalDay, familyDay: familyDay, atTop: $historyAtTop)
                                    .id(calendar.startOfDay(for: date))
                            }
                            .frame(width: viewport.size.width, height: height)
                            .offset(y: (showingDayHistory ? 0 : height) + pageDrag)
                            .allowsHitTesting(showingDayHistory && !paging).accessibilityHidden(!showingDayHistory)
                        }
                        .contentShape(Rectangle()).clipped()
                        .simultaneousGesture(verticalPaging(height: height))
                    }
                }.padding(.top, 4).padding(.bottom, 8)

            }
            .background { FolkiBackground() }
            .navigationTitle("Бюджет")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { headerActions }
            .onAppear { FolkiFeedback.prepare() }
        }
        .sheet(item: $editingRecord) { ExpenseEditorView(session: session, editing: $0) }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .setup: DailyFundingView(personal: personal, family: family, initialScope: selectedScope)
            case .spend: QuickSpendView(personal: personal, family: family)
            case .income: DailyFundingView(personal: personal, family: family, initialScope: selectedScope)
            case .expense: ExpenseEditorView(session: session, initialKind: entryKind)
            case .contribution: ContributionView(personal: personal, family: family)
            case .limits: SpendingLimitsView(personal: personal, family: family, scope: selectedScope)
            case .settings: BudgetSettingsView(personal: personal, family: family)
            case .details: BudgetCalculationView(personal: personalDay.result, family: familyDay.result, date: date)
            case .distribution:
                DistributionChoiceView(day: Binding(get: { session.distributionDay }, set: { session.distributionDay = $0 }),
                    apply: { try session.setDistributionDay($0) })
            case .envelopes: BudgetSetupView(session: session, editingCurrent: true)
            }
        }
    }

    private func showHistory(_ show: Bool) {
        paging = true
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.55), completionCriteria: .removed) {
            showingDayHistory = show; pageDrag = 0
        } completion: { paging = false }
    }

    private func verticalPaging(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) * 1.3 else { return }
                if showingDayHistory {
                    guard historyAtTop, value.translation.height > 0 else { return }
                    pageDrag = min(height, value.translation.height)
                } else {
                    pageDrag = max(-height, min(0, value.translation.height))
                }
            }
            .onEnded { value in
                let distance = value.translation.height
                let predicted = value.predictedEndTranslation.height
                let vertical = abs(distance) > abs(value.translation.width) * 1.3
                if vertical && !showingDayHistory && (distance < -64 || predicted < -height * 0.3) {
                    showHistory(true)
                } else if vertical && showingDayHistory && historyAtTop && (distance > 64 || predicted > height * 0.3) {
                    showHistory(false)
                } else {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { pageDrag = 0 }
                }
            }
    }

    private var distributionLine: some View {
        VStack(spacing: 12) {
            if personal.hasFunding {
                Button {
                    selectedScope = .personal; sheet = .distribution
                } label: {
                    Text(personal.periodTitle).font(.footnote).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }

        }
    }

    private func toggleRingPeriod() {
        FolkiFeedback.selection()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.7)) { showsMonth.toggle() }
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
        selectedDay = calendar.isDate(target, inSameDayAs: today) ? nil : target
    }

    private var weekCalendar: some View {
        BudgetWeekCalendar(selection: $selectedDay, today: session.referenceDate, calendar: calendar, showsFamily: family.household != nil) { day in
            (personal.overview(on: day).result?.dayRingFraction, family.overview(on: day).result?.dayRingFraction)
        }
    }

    private var headerActions: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            NavigationLink {
                ScopedScreen(personal: personal, family: family, title: String(localized: "Аналитика")) {
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

    private func entryArea(date: Date, personalDay: BudgetDayOverview, familyDay: BudgetDayOverview) -> some View {
        ZStack(alignment: .top) {
            if selectedDay == nil {
                VStack(spacing: 10) {
                    spendButton.padding(.horizontal, -8)
                }.transition(.opacity)
            } else {
                BudgetDaySpendingSummary(date: date, personal: personal, family: family,
                                         personalDay: personalDay, familyDay: familyDay)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedDay == nil)
    }

    private var spendButton: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return GlassEffectContainer(spacing: 12) {
        layout {
            Button {
                returnToToday {
                    sheet = .spend
                }
            } label: {
                Text("− Потратить").frame(maxWidth: .infinity).frame(minHeight: 70)
                    .foregroundStyle(.white)
                    .glassEffect(.regular.tint(Color.folkiAccent).interactive(), in: Capsule())
            }
            .buttonStyle(FolkiPressStyle())
            .frame(minWidth: 104, maxWidth: .infinity)
            Menu {
                Button("В личный бюджет", systemImage: "person") { selectedScope = .personal; sheet = .income }
                if family.household != nil {
                    Button("В семейный бюджет", systemImage: "person.2") { selectedScope = .family; sheet = .income }
                    Button("Взнос в семейный", systemImage: "arrow.right.circle") { openContribution() }
                }
            } label: {
                Text("+ Внести").frame(maxWidth: .infinity, minHeight: 70)
                    .glassEffect(.regular.interactive(), in: Capsule()).foregroundStyle(Color.folkiInk)
            }
            .menuStyle(.button).buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { returnToToday() })
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
            sheet = kind == .income ? .income : .expense
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
                calculation(personal, title: String(localized: "Личный бюджет"))
                calculation(family, title: String(localized: "Семейный бюджет"))
                Section("Кольца") {
                    Text("Снаружи — личный бюджет, внутри — семейный. Нажми на кольца, чтобы переключить день и период.")
                    Text("Накопления сюда не входят. Прогноз — если сегодня больше ничего не тратить.")
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
                LabeledContent("План на период", value: MoneyText.whole(result.periodPlan))
                LabeledContent("Остаток периода", value: MoneyText.whole(result.periodRemaining))
                LabeledContent("Из них на повседневное", value: MoneyText.whole(result.monthlyRemaining))
            } else { Text("Тут пока нет плана").foregroundStyle(.secondary) }
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
        case .expense: String(localized: "Трата"); case .refund: String(localized: "Возврат"); case .income: String(localized: "Поступление")
        case .reserveAllocation: String(localized: "В накопления"); case .reserveRelease: String(localized: "Из накоплений")
        case .contributionOut: String(localized: "Взнос в семейный"); case .contributionIn: String(localized: "Взнос участника")
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
            .accessibilityLabel([kindTitle, record.title.isEmpty ? category?.name ?? String(localized: "Другое") : record.title,
                session.payerName(for: record), record.transaction.date.formatted(.dateTime.day().month(.wide).year()),
                record.transaction.isDeleted ? String(localized: "Удалённая запись") : ""].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityValue(MoneyText.string(record.transaction.amount))
    }
}

extension View {
    func budgetCard() -> some View {
        padding(FolkiSpacing.card).frame(maxWidth: .infinity, alignment: .leading)
            .folkiGlass(RoundedRectangle(cornerRadius: 20))
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                     count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                      alignment: .leading, spacing: FolkiSpacing.card) {
                summary(personal, overview: personalDay)
                summary(family, overview: familyDay)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ session: BudgetSession, overview: BudgetDayOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.scope.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.budget(session.scope))
            if overview.errorMessage != nil {
                Text("Не получилось загрузить").font(.footnote).foregroundStyle(.secondary)
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
                Text("Не получилось посчитать").font(.footnote).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}
