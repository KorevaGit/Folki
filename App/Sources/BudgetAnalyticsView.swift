import SwiftUI
import Charts
import FolkiDuoCore

struct BudgetAnalyticsSection: View {
    let session: BudgetSession
    let date: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var period: AnalyticsPeriod = .month
    @State private var chosenDate: Date?
    @State private var showsAllCategories = false
    @State private var showsEnvelopeSpending = false
    private var baseDate: Date { chosenDate ?? date }
    private var selectedPeriod: BudgetPeriod? { session.period(on: baseDate) }
    private var anchor: Date {
        if period == .month, let selectedPeriod {
            return min(selectedPeriod.endExclusive.addingTimeInterval(-0.001), session.referenceDate)
        }
        guard let interval = analyticsCalendar.dateInterval(of: component, for: baseDate) else { return baseDate }
        return min(interval.end.addingTimeInterval(-0.001), session.referenceDate)
    }
    private var analyticsCalendar: Calendar { session.calendar }
    private var component: Calendar.Component {
        switch period { case .day: .day; case .week: .weekOfYear; case .month: .month }
    }
    private var canGoBack: Bool {
        guard period == .month, let selectedPeriod else { return true }
        return session.periods.contains { $0.start < selectedPeriod.start }
    }
    private var canGoForward: Bool {
        if period == .month, let selectedPeriod {
            return session.periods.contains { $0.start > selectedPeriod.start && $0.start <= session.referenceDate }
        }
        return analyticsCalendar.dateInterval(of: component, for: anchor).map { $0.end <= session.referenceDate } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // A single day is already on the main screen's calendar.
            FolkiSegmentedPicker(title: String(localized: "Период аналитики"), selection: $period,
                options: [AnalyticsPeriod.week, .month].map { ($0.title, $0) })
            if let result = try? session.analytics(period, on: baseDate) {
                periodNavigation(result)
                let monthPlan = period == .month ? session.overview(on: result.cutoff).result : nil
                if period == .month, let plan = monthPlan {
                    pace(result, plan: plan).folkiAppear(1)
                } else {
                    overview(result).folkiAppear(1)
                }
                if result.recordCount == 0 {
                    ContentUnavailableView("Пока без операций", systemImage: "chart.bar.xaxis",
                        description: Text("Запиши первую трату — здесь появится, на что уходят деньги"))
                }
                if result.expenses.minorUnits > 0 || result.refunds.minorUnits > 0 {
                    spendingSources(result).folkiAppear(3)
                    needsAndWants(result).folkiAppear(3)
                    chart(result, plan: monthPlan).budgetCard().folkiAppear(4)
                    categories(result, plan: monthPlan).folkiAppear(6)
                }
                if result.contributions.minorUnits > 0 || result.reserveTransfers.minorUnits != 0 {
                    transfers(result)
                }
                NavigationLink {
                    BudgetHistoryView(session: session).toolbar(.visible, for: .navigationBar)
                } label: {
                    Label("Все операции этого бюджета", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(FolkiSoftButtonStyle())
            } else {
                ContentUnavailableView("Не получилось посчитать", systemImage: "chart.bar.xaxis",
                    description: Text("Открой историю операций и попробуй ещё раз"))
            }
        }
        .environment(\.calendar, analyticsCalendar).environment(\.timeZone, session.calendar.timeZone)
    }

    private func periodNavigation(_ result: BudgetAnalyticsSnapshot) -> some View {
        HStack(spacing: 12) {
            Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                .buttonStyle(FolkiSoftButtonStyle()).buttonBorderShape(.circle).disabled(!canGoBack).accessibilityLabel("Предыдущий период")
            VStack(spacing: 4) {
                if period == .day {
                    Text(result.interval.start, format: .dateTime.day().month(.wide).year())
                } else {
                    Text("\(result.interval.start.formatted(.dateTime.day().month(.abbreviated))) — \(result.interval.end.addingTimeInterval(-0.001).formatted(.dateTime.day().month(.abbreviated).year()))")
                }
            }.font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                .buttonStyle(FolkiSoftButtonStyle()).buttonBorderShape(.circle).disabled(!canGoForward)
                .accessibilityLabel("Следующий период")
        }
    }

    private func move(_ offset: Int) {
        if period == .month, let selectedPeriod,
           let index = session.periods.firstIndex(of: selectedPeriod) {
            let next = index + offset
            guard session.periods.indices.contains(next) else { return }
            chosenDate = session.periods[next].start
        } else if let next = analyticsCalendar.date(byAdding: component, value: offset, to: anchor) {
            chosenDate = min(next, session.referenceDate)
        }
        FolkiFeedback.selection()
    }

    private func overview(_ result: BudgetAnalyticsSnapshot) -> some View {
        let net = (try? result.netSpending) ?? result.expenses
        return VStack(alignment: .leading, spacing: 16) {
            Text(net.minorUnits < 0 ? String(localized: "Вернули больше, чем потрачено") : String(localized: "Потрачено"))
                .font(.headline).foregroundStyle(.secondary)
            Text(MoneyText.whole(net)).font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
            extraRows(result)
        }.budgetCard()
    }

    private func spendingSources(_ result: BudgetAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Из чего состоят расходы").font(.headline)
            amountRow(String(localized: "Из конвертов"), result.envelopeNetSpending)
            amountRow(String(localized: "На жизнь"), result.flexibleNetSpending)
            Divider()
            amountRow(String(localized: "Всего потрачено"), (try? result.netSpending) ?? result.expenses)
            Text("С учётом возвратов. Пополнение конвертов — не расход.")
                .font(.footnote).foregroundStyle(.secondary)
        }.budgetCard()
    }

    /// Refunds and income only when they happened: zero rows are noise.
    @ViewBuilder private func extraRows(_ result: BudgetAnalyticsSnapshot) -> some View {
        if result.refunds.minorUnits > 0 || result.income.minorUnits > 0 {
            Divider()
            if result.refunds.minorUnits > 0 { amountRow(String(localized: "Вернули деньги"), result.refunds) }
            if result.income.minorUnits > 0 { amountRow(String(localized: "Пришло денег"), result.income) }
        }
    }

    /// The month against its plan: how much is spent, and where the spending should be by today.
    private func pace(_ result: BudgetAnalyticsSnapshot, plan snapshot: DailyBudgetSnapshot) -> some View {
        let net = (try? result.netSpending) ?? result.expenses
        let plan = snapshot.periodPlan.minorUnits
        let days = max(1, result.buckets.count)
        let passed = result.buckets.filter(\.isObserved).count
        let expected = plan / Int64(days) * Int64(passed) + (plan % Int64(days)) * Int64(passed) / Int64(days)
        let spentFraction = plan > 0 ? Double(max(0, net.minorUnits)) / Double(plan) : 0
        let expectedFraction = Double(passed) / Double(max(1, days))
        let ahead = net.minorUnits - expected
        let finished = passed >= days
        return VStack(alignment: .leading, spacing: 14) {
            Text("Как идёт период").font(.headline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(MoneyText.whole(net)).font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    .contentTransition(.numericText(value: Double(net.minorUnits))).animation(FolkiMotion.quick, value: net.minorUnits)
                if plan > 0 {
                    Text("из \(MoneyText.whole(snapshot.periodPlan))").font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            if plan > 0 {
                PaceBar(spent: spentFraction, expected: finished ? nil : expectedFraction,
                        over: net.minorUnits > plan)
                Text(finished ? String(localized: "Период завершён") : String(localized: "Прошло \(passed) из \(days) дней"))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(verdict(ahead: ahead, overPlan: net.minorUnits - plan, finished: finished, passed: passed, snapshot: snapshot))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(net.minorUnits > plan ? Color.folkiOver : Color.folkiInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            extraRows(result)
        }.budgetCard()
    }

    private func verdict(ahead: Int64, overPlan: Int64, finished: Bool, passed: Int, snapshot: DailyBudgetSnapshot) -> String {
        if overPlan > 0 { return String(localized: "План превышен на \(MoneyText.whole(Money(minorUnits: overPlan).roundedUpToWholeUnits))") }
        // Round to 100 ₽: an estimate should not look more exact than it is.
        let gap = MoneyText.whole(Money(minorUnits: abs(ahead) / 10_000 * 10_000))
        if finished { return String(localized: "Период закончился, осталось \(gap)") }
        // A few days say nothing about the pace yet.
        if passed < 7 { return String(localized: "Темп покажу через неделю — пока мало дней") }
        if ahead <= 0 { return String(localized: "Траты медленнее плана на \(gap)") }
        if let next = snapshot.futureAllocation {
            return String(localized: "Тратишь быстрее плана на \(gap). Дальше лучше держаться около \(MoneyText.whole(next.firstDayAmount.roundedDownToWholeUnits)) в день")
        }
        return String(localized: "Тратишь быстрее плана на \(gap)")
    }

    private func amountRow(_ title: String, _ amount: Money) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Text(title).foregroundStyle(.secondary)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(MoneyText.whole(amount)).fontWeight(.semibold).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
        }.font(.subheadline)
    }

    private struct PlotPoint: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }
    @ViewBuilder private func chart(_ result: BudgetAnalyticsSnapshot, plan: DailyBudgetSnapshot?) -> some View {
        if period == .month, let plan, plan.periodPlan.minorUnits > 0 {
            monthLine(result, plan: plan)
        } else {
            dailyBars(result)
        }
    }

    /// Running total against an even spend of the plan: above the dashed line means faster than planned.
    private func monthLine(_ result: BudgetAnalyticsSnapshot, plan: DailyBudgetSnapshot) -> some View {
        var running = 0.0
        let points = result.buckets.filter(\.isObserved).map { bucket -> PlotPoint in
            running += Double(bucket.expenses.minorUnits - bucket.refunds.minorUnits) / 100
            return PlotPoint(date: max(bucket.start, result.interval.start), value: running)
        }
        let planned = Double(plan.periodPlan.minorUnits) / 100
        let end = result.interval.end
        return VStack(alignment: .leading, spacing: 12) {
            Text("Траты за период").font(.headline)
            HStack(spacing: 14) {
                Label("факт", systemImage: "circle.fill").foregroundStyle(Color.folkiAccent)
                Label("ровно по плану", systemImage: "line.diagonal").foregroundStyle(.secondary)
            }.font(.caption).labelStyle(.titleAndIcon).imageScale(.small)
            Chart {
                LineMark(x: .value(String(localized: "Дата"), result.interval.start), y: .value(String(localized: "План"), 0), series: .value(String(localized: "Ряд"), String(localized: "план")))
                    .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                LineMark(x: .value(String(localized: "Дата"), end), y: .value(String(localized: "План"), planned), series: .value(String(localized: "Ряд"), String(localized: "план")))
                    .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                ForEach(points) { point in
                    AreaMark(x: .value(String(localized: "Дата"), point.date), y: .value(String(localized: "Рубли"), point.value))
                        .foregroundStyle(Color.folkiAccent.opacity(0.12)).interpolationMethod(.monotone)
                    LineMark(x: .value(String(localized: "Дата"), point.date), y: .value(String(localized: "Рубли"), point.value), series: .value(String(localized: "Ряд"), String(localized: "факт")))
                        .foregroundStyle(Color.folkiAccent).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: result.interval.start...end)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine(); AxisValueLabel(format: .dateTime.day())
                }
            }
            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 240 : 180)
            .accessibilityLabel("Траты за период нарастающим итогом и ровный темп по плану")
        }
    }

    private func dailyBars(_ result: BudgetAnalyticsSnapshot) -> some View {
        let points = result.buckets.filter(\.isObserved).map {
            PlotPoint(date: $0.start, value: Double($0.expenses.minorUnits - $0.refunds.minorUnits) / 100)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(period == .day ? String(localized: "Траты по часам") : String(localized: "Траты по дням")).font(.headline)
            Chart(points) { point in
                BarMark(x: .value(String(localized: "Дата"), point.date, unit: period == .day ? .hour : .day), y: .value(String(localized: "Рубли"), point.value))
                    .foregroundStyle(Color.folkiAccent).cornerRadius(4)
            }
            .chartXScale(domain: result.interval.start...result.interval.end)
            .chartXAxis {
                AxisMarks(values: .stride(by: period == .day ? .hour : .day, count: period == .day ? 6 : period == .month ? 7 : 1)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: period == .day ? .dateTime.hour() : period == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day())
                }
            }
            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 240 : 180)
            .accessibilityLabel(period == .day ? String(localized: "Расходы по часам с учётом возвратов") : String(localized: "Расходы по дням с учётом возвратов"))
        }
    }

    private func net(_ item: CategorySpending) -> Money {
        (try? item.expenses.subtracting(item.refunds)) ?? item.expenses
    }
    private func categories(_ result: BudgetAnalyticsSnapshot, plan: DailyBudgetSnapshot?) -> some View {
        let source = showsEnvelopeSpending ? result.envelopeCategories : result.everydayCategories
        let sorted = source.sorted { net($0).minorUnits > net($1).minorUnits }
        let positiveTotal = sorted.reduce(Int64(0)) { $0 + max(0, net($1).minorUnits) }
        let items = showsAllCategories ? sorted : Array(sorted.prefix(5))
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("На что ушли деньги").font(.headline)
                FolkiSegmentedPicker(title: String(localized: "Источник расходов"), selection: $showsEnvelopeSpending,
                    options: [(String(localized: "На жизнь"), false), (String(localized: "Конверты"), true)])
            }
            if items.isEmpty {
                Text("В этой группе пока нет расходов").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                let category = session.catalog.category(for: item.categoryID)
                let amount = net(item)
                VStack(alignment: .leading, spacing: 8) {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        Label { Text(category.name) } icon: { CategoryIcon(category: category, size: 32) }
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(MoneyText.whole(amount)).fontWeight(.semibold).monospacedDigit()
                                .foregroundStyle(Color.folkiInk)
                        }.lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
                    }.font(.subheadline).frame(minHeight: 44)
                    if positiveTotal > 0 {
                        ProgressView(value: Double(max(0, amount.minorUnits)) / Double(positiveTotal))
                            .tint(category.color.color)
                    }
                    if amount.minorUnits < 0 {
                        Text("Вернули больше, чем потратили").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if sorted.count > 5 {
                Button(showsAllCategories ? String(localized: "Свернуть") : String(localized: "Все категории (\(sorted.count))")) {
                    FolkiFeedback.selection(); withAnimation(FolkiMotion.quick) { showsAllCategories.toggle() }
                }.buttonStyle(FolkiSoftButtonStyle()).frame(maxWidth: .infinity)
            }
        }.budgetCard()
    }

    /// Needs against wants, as shares of what was spent. No target to measure against.
    @ViewBuilder private func needsAndWants(_ result: BudgetAnalyticsSnapshot) -> some View {
        let needs = max(0, result.essentialSpending.minorUnits), wants = max(0, result.wantsSpending.minorUnits)
        if needs + wants > 0 {
            let share = Double(needs) / Double(needs + wants)
            VStack(alignment: .leading, spacing: 10) {
                Text("Обязательные и желания").font(.headline)
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        Capsule().fill(Color.folkiAccent).frame(width: max(0, (geo.size.width - 2) * share))
                        Capsule().fill(Color.secondary.opacity(0.35))
                    }
                }.frame(height: 8).accessibilityHidden(true)
                Text("Обязательные \(Int((share * 100).rounded()))% · желания \(100 - Int((share * 100).rounded()))%")
                    .font(.subheadline).monospacedDigit()
            }.budgetCard()
        }
    }

    private func transfers(_ result: BudgetAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Взносы и накопления").font(.headline)
            if result.contributions.minorUnits > 0 {
                amountRow(session.scope == .personal ? String(localized: "Переведено в семейный") : String(localized: "Взносы в семейный"), result.contributions)
            }
            if result.reserveTransfers.minorUnits != 0 {
                amountRow(result.reserveTransfers.minorUnits > 0 ? String(localized: "Отложено в накопления") : String(localized: "Взято из накоплений"),
                          Money(minorUnits: abs(result.reserveTransfers.minorUnits)))
            }
            if !result.contributionsByMember.isEmpty {
                Divider()
                Text("Кто сколько внёс").font(.subheadline.weight(.semibold))
                ForEach(result.contributionsByMember) { item in
                    amountRow(session.memberName(item.memberID), item.amount)
                }
            }
            Text("Это не траты: деньги остаются в семье").font(.footnote).foregroundStyle(.secondary)
        }.budgetCard()
    }
}

/// Spent share of the plan, with a tick where spending should be by today.
private struct PaceBar: View {
    let spent: Double
    let expected: Double?
    let over: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.folkiAccent.opacity(0.15))
                Capsule().fill(over ? Color.folkiOver : Color.folkiAccent)
                    .frame(width: max(10, geo.size.width * min(1, spent)))
                if let expected {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.folkiInk)
                        .frame(width: 3, height: geo.size.height + 8)
                        .offset(x: geo.size.width * min(1, expected) - 1.5)
                }
            }
        }
        .frame(height: 12).padding(.vertical, 4)
        .accessibilityElement()
        .accessibilityLabel("Потрачено \(Int((spent * 100).rounded())) процентов плана")
        .accessibilityValue(expected.map { String(localized: "К сегодняшнему дню по плану \(Int(($0 * 100).rounded())) процентов") } ?? "")
    }
}

/// A screen about one budget, with the personal/family switch on top when there is a family.
struct ScopedScreen<Content: View>: View {
    let personal: BudgetSession
    let family: BudgetSession
    let title: String
    var initial: BudgetScope = .personal
    @ViewBuilder let content: (BudgetSession) -> Content
    @State private var scope: BudgetScope?

    var body: some View {
        let current = family.household == nil ? .personal : scope ?? initial
        ScrollView {
            VStack(alignment: .leading, spacing: FolkiSpacing.card) {
                if family.household != nil {
                    FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: Binding(get: { current }, set: { scope = $0 }),
                        options: BudgetScope.allCases.map { ($0.title, $0) })
                }
                content(current == .personal ? personal : family).id(current)
            }.folkiPagePadding()
        }
        .background { FolkiBackground() }
        .navigationTitle(title).toolbarTitleDisplayMode(.inlineLarge)
        .toolbar(.visible, for: .navigationBar)
    }
}
