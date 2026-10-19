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
    /// The whole period up to today: a past month ends on its last day, not on today's day number.
    private var anchor: Date {
        let base = chosenDate ?? date
        guard let interval = analyticsCalendar.dateInterval(of: component, for: base) else { return base }
        return min(interval.end.addingTimeInterval(-1), session.referenceDate)
    }
    private var analyticsCalendar: Calendar {
        var calendar = session.calendar
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    private var component: Calendar.Component {
        switch period { case .day: .day; case .week: .weekOfYear; case .month: .month }
    }
    private var canGoForward: Bool {
        analyticsCalendar.dateInterval(of: component, for: anchor).map { $0.end <= session.referenceDate } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // A single day is already on the main screen's calendar.
            FolkiSegmentedPicker(title: "Период аналитики", selection: $period,
                options: [AnalyticsPeriod.week, .month].map { ($0.title, $0) })
            if let result = try? BudgetAnalytics.calculate(records: session.historyRecords, period: period,
                anchor: anchor, asOf: session.referenceDate, calendar: session.calendar, catalog: session.catalog) {
                periodNavigation(result)
                let monthPlan = period == .month ? session.overview(on: result.cutoff).result : nil
                let insights = PeriodInsights(result: result, records: session.historyRecords, catalog: session.catalog,
                                              snapshot: monthPlan, isMonth: period == .month)
                if let tip = insights.tip { InsightTip(text: tip) }
                if period == .month, let plan = monthPlan {
                    pace(result, plan: plan)
                } else {
                    overview(result)
                }
                changes(result)
                if result.recordCount == 0 {
                    ContentUnavailableView("Пока без операций", systemImage: "chart.bar.xaxis",
                        description: Text("За этот период нет записей. Выбери другой период или добавь трату через «Потратить»."))
                }
                if result.expenses.minorUnits > 0 || result.refunds.minorUnits > 0 {
                    if period == .month { balance(result) }
                    chart(result, plan: monthPlan).budgetCard()
                    HabitsCard(insights: insights)
                    categories(result)
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
                ContentUnavailableView("Не удалось посчитать", systemImage: "chart.bar.xaxis",
                    description: Text("Открой историю и проверь записи, затем попробуй снова."))
            }
        }
        .environment(\.calendar, analyticsCalendar).environment(\.timeZone, session.calendar.timeZone)
    }

    private func periodNavigation(_ result: BudgetAnalyticsSnapshot) -> some View {
        HStack(spacing: 12) {
            Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                .buttonStyle(FolkiSoftButtonStyle()).buttonBorderShape(.circle).accessibilityLabel("Предыдущий период")
            VStack(spacing: 4) {
                if period == .day {
                    Text(result.interval.start, format: .dateTime.day().month(.wide).year())
                } else {
                    Text("\(result.interval.start.formatted(.dateTime.day().month(.abbreviated))) — \(result.cutoff.formatted(.dateTime.day().month(.abbreviated).year()))")
                }
                Text("\(session.scope.title) бюджет").font(.caption).foregroundStyle(.secondary)
            }.font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                .buttonStyle(FolkiSoftButtonStyle()).buttonBorderShape(.circle).disabled(!canGoForward)
                .accessibilityLabel("Следующий период")
        }
    }

    private func move(_ offset: Int) {
        guard let next = analyticsCalendar.date(byAdding: component, value: offset, to: anchor) else { return }
        FolkiFeedback.selection()
        chosenDate = min(next, session.referenceDate)
    }

    private func overview(_ result: BudgetAnalyticsSnapshot) -> some View {
        let net = (try? result.netSpending) ?? result.expenses
        return VStack(alignment: .leading, spacing: 16) {
            Text(net.minorUnits < 0 ? "Вернули больше, чем потрачено" : "Потрачено")
                .font(.headline).foregroundStyle(.secondary)
            Text(MoneyText.whole(net)).font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
            extraRows(result)
        }.budgetCard()
    }

    /// Refunds and income only when they happened: zero rows are noise.
    @ViewBuilder private func extraRows(_ result: BudgetAnalyticsSnapshot) -> some View {
        if result.refunds.minorUnits > 0 || result.income.minorUnits > 0 {
            Divider()
            if result.refunds.minorUnits > 0 { amountRow("Вернули деньги", result.refunds) }
            if result.income.minorUnits > 0 { amountRow("Пришло денег", result.income) }
        }
    }

    /// The month against its plan: how much is spent, and where the spending should be by today.
    private func pace(_ result: BudgetAnalyticsSnapshot, plan snapshot: DailyBudgetSnapshot) -> some View {
        let net = (try? result.netSpending) ?? result.expenses
        let plan = snapshot.monthlyPlan.minorUnits
        let cal = analyticsCalendar
        let days = cal.range(of: .day, in: .month, for: result.interval.start)?.count ?? 30
        let passed = min(days, (cal.dateComponents([.day], from: result.interval.start, to: result.cutoff).day ?? 0) + 1)
        let expected = plan * Int64(passed) / Int64(max(1, days))
        let spentFraction = plan > 0 ? Double(max(0, net.minorUnits)) / Double(plan) : 0
        let expectedFraction = Double(passed) / Double(max(1, days))
        let ahead = net.minorUnits - expected
        let finished = passed >= days
        return VStack(alignment: .leading, spacing: 14) {
            Text("Как идёт месяц").font(.headline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(MoneyText.whole(net)).font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                if plan > 0 {
                    Text("из \(MoneyText.whole(snapshot.monthlyPlan))").font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            if plan > 0 {
                PaceBar(spent: spentFraction, expected: finished ? nil : expectedFraction,
                        over: net.minorUnits > plan)
                Text(finished ? "Месяц завершён" : "Прошло \(passed) из \(days) дней")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(verdict(ahead: ahead, overPlan: net.minorUnits - plan, finished: finished, snapshot: snapshot))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(net.minorUnits > plan ? Color.red : Color.folkiInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            extraRows(result)
        }.budgetCard()
    }

    private func verdict(ahead: Int64, overPlan: Int64, finished: Bool, snapshot: DailyBudgetSnapshot) -> String {
        if overPlan > 0 { return "План превышен на \(MoneyText.whole(Money(minorUnits: overPlan).roundedUpToWholeUnits))" }
        // Round to 100 ₽: an estimate should not look more exact than it is.
        let gap = MoneyText.whole(Money(minorUnits: abs(ahead) / 10_000 * 10_000))
        if finished { return "Уложился в план, осталось \(gap)" }
        if ahead <= 0 { return "Идёшь с запасом \(gap) — так держать" }
        if let next = snapshot.futureAllocation {
            return "Тратишь быстрее плана на \(gap). Дальше лучше держаться около \(MoneyText.whole(next.firstDayAmount.roundedDownToWholeUnits)) в день"
        }
        return "Тратишь быстрее плана на \(gap)"
    }

    /// Categories that changed noticeably against the same stretch of the previous period.
    @ViewBuilder private func changes(_ result: BudgetAnalyticsSnapshot) -> some View {
        let cal = analyticsCalendar
        if let previousAnchor = cal.date(byAdding: component, value: -1, to: result.cutoff),
           let previous = try? BudgetAnalytics.calculate(records: session.historyRecords, period: period,
                anchor: previousAnchor, asOf: previousAnchor, calendar: session.calendar, catalog: session.catalog),
           previous.recordCount > 0 {
            let before = Dictionary(previous.categories.map { ($0.categoryID, net($0).minorUnits) }, uniquingKeysWith: +)
            let now = Dictionary(result.categories.map { ($0.categoryID, net($0).minorUnits) }, uniquingKeysWith: +)
            let items = Set(before.keys).union(now.keys).compactMap { id -> (UUID, Int64, Int64)? in
                let old = before[id] ?? 0, new = now[id] ?? 0, diff = new - old
                // Ignore small moves: under 300 ₽ or under a fifth of the old amount.
                guard abs(diff) >= 30_000, old == 0 || abs(diff) * 5 >= abs(old) else { return nil }
                return (id, diff, old)
            }.sorted { abs($0.1) > abs($1.1) }.prefix(3)
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Что изменилось").font(.headline)
                    Text(period == .month ? "По сравнению с тем же днём прошлого месяца" : "По сравнению с прошлой неделей на этот день")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(items), id: \.0) { id, diff, old in
                        let category = session.catalog.category(for: id)
                        HStack(spacing: 12) {
                            CategoryIcon(category: category, size: 32)
                            Text(category.name).font(.subheadline)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text((diff > 0 ? "+" : "−") + MoneyText.whole(Money(minorUnits: abs(diff)).roundedDownToWholeUnits))
                                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(diff > 0 ? Color.budget(.personal) : Color.budget(.family))
                                if old > 0 {
                                    Text("\(diff > 0 ? "+" : "−")\(Int((Double(abs(diff)) / Double(old) * 100).rounded()))%")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.budgetCard()
            }
        }
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
        if period == .month, let plan, plan.monthlyPlan.minorUnits > 0 {
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
            return PlotPoint(date: bucket.start, value: running)
        }
        let planned = Double(plan.monthlyPlan.minorUnits) / 100
        let end = result.interval.end
        return VStack(alignment: .leading, spacing: 12) {
            Text("Траты за месяц").font(.headline)
            HStack(spacing: 14) {
                Label("факт", systemImage: "circle.fill").foregroundStyle(Color.folkiAccent)
                Label("ровно по плану", systemImage: "line.diagonal").foregroundStyle(.secondary)
            }.font(.caption).labelStyle(.titleAndIcon).imageScale(.small)
            Chart {
                LineMark(x: .value("Дата", result.interval.start), y: .value("План", 0), series: .value("Ряд", "план"))
                    .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                LineMark(x: .value("Дата", end), y: .value("План", planned), series: .value("Ряд", "план"))
                    .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                ForEach(points) { point in
                    AreaMark(x: .value("Дата", point.date), y: .value("Рубли", point.value))
                        .foregroundStyle(Color.folkiAccent.opacity(0.12)).interpolationMethod(.monotone)
                    LineMark(x: .value("Дата", point.date), y: .value("Рубли", point.value), series: .value("Ряд", "факт"))
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
            .accessibilityLabel("Траты за месяц нарастающим итогом и ровный темп по плану")
        }
    }

    private func dailyBars(_ result: BudgetAnalyticsSnapshot) -> some View {
        let points = result.buckets.filter(\.isObserved).map {
            PlotPoint(date: $0.start, value: Double($0.expenses.minorUnits - $0.refunds.minorUnits) / 100)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(period == .day ? "Траты по часам" : "Траты по дням").font(.headline)
            Chart(points) { point in
                BarMark(x: .value("Дата", point.date, unit: period == .day ? .hour : .day), y: .value("Рубли", point.value))
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
            .accessibilityLabel(period == .day ? "Расходы по часам с учётом возвратов" : "Расходы по дням с учётом возвратов")
        }
    }

    private func net(_ item: CategorySpending) -> Money {
        (try? item.expenses.subtracting(item.refunds)) ?? item.expenses
    }
    private func categories(_ result: BudgetAnalyticsSnapshot) -> some View {
        let sorted = result.categories.sorted { net($0).minorUnits > net($1).minorUnits }
        let positiveTotal = sorted.reduce(Int64(0)) { $0 + max(0, net($1).minorUnits) }
        let items = showsAllCategories ? sorted : Array(sorted.prefix(5))
        return VStack(alignment: .leading, spacing: 16) {
            Text("На что ушли деньги").font(.headline)
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
                        Text(MoneyText.whole(amount)).fontWeight(.semibold).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
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
                Button(showsAllCategories ? "Свернуть" : "Все категории (\(sorted.count))") {
                    withAnimation(.snappy) { showsAllCategories.toggle() }
                }.buttonStyle(FolkiSoftButtonStyle()).frame(maxWidth: .infinity)
            }
        }.budgetCard()
    }

    /// The beginner's 50/30/20 frame: needs, wants and money put aside, as shares of this month's money.
    /// Counted from what was actually spent and saved, so it works without recording income.
    @ViewBuilder private func balance(_ result: BudgetAnalyticsSnapshot) -> some View {
        let needs = max(0, result.essentialSpending.minorUnits)
        let wants = max(0, result.wantsSpending.minorUnits)
        let saved = max(0, result.reserveTransfers.minorUnits)
        let total = needs + wants + saved
        if total > 0 {
            let parts: [(String, String, Int64, Int, Color)] = [
                ("Обязательное", "жильё, еда, транспорт", needs, 50, Color.budget(.family)),
                ("Желания", "кафе, покупки, развлечения", wants, 30, Color.budget(.personal)),
                ("Отложено", "в накопления", saved, 20, Color.folkiAccent)]
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Баланс месяца").font(.headline)
                    Text("Простой ориентир: 50% на обязательное, 30% на желания, 20% отложить.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(parts, id: \.0) { title, hint, amount, target, color in
                    let share = Int((Double(amount) / Double(total) * 100).rounded())
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(title).font(.subheadline.weight(.semibold))
                            Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(share)%").font(.subheadline.weight(.bold)).monospacedDigit()
                            Text("/ \(target)%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ShareBar(share: Double(share) / 100, target: Double(target) / 100, color: color)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(balanceAdvice(needs: needs, wants: wants, saved: saved, total: total))
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }.budgetCard()
        }
    }

    private func balanceAdvice(needs: Int64, wants: Int64, saved: Int64, total: Int64) -> String {
        let wantsShare = Double(wants) / Double(total), savedShare = Double(saved) / Double(total)
        if saved == 0 { return "В этом месяце пока ничего не отложено. Начни с малого: даже 5% в накопления — уже привычка." }
        if wantsShare > 0.35 { return "Желаний больше ориентира. Это не плохо, просто стоит знать, куда уходят деньги." }
        if savedShare >= 0.2 { return "Откладываешь 20% и больше — отличный темп." }
        return "Хороший баланс. Если получится, понемногу увеличивай долю накоплений."
    }

    private func transfers(_ result: BudgetAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Взносы и накопления").font(.headline)
            if result.contributions.minorUnits > 0 {
                amountRow(session.scope == .personal ? "Переведено в семейный" : "Взносы в семейный", result.contributions)
            }
            if result.reserveTransfers.minorUnits != 0 {
                amountRow(result.reserveTransfers.minorUnits > 0 ? "Отложено в накопления" : "Взято из накоплений",
                          Money(minorUnits: abs(result.reserveTransfers.minorUnits)))
            }
            if !result.contributionsByMember.isEmpty {
                Divider()
                Text("Кто сколько внёс").font(.subheadline.weight(.semibold))
                ForEach(result.contributionsByMember) { item in
                    amountRow(session.memberName(item.memberID), item.amount)
                }
            }
            Text("Это не траты: деньги остаются в семье.").font(.footnote).foregroundStyle(.secondary)
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
                Capsule().fill(over ? Color.red : Color.folkiAccent)
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
        .accessibilityValue(expected.map { "К сегодняшнему дню по плану \(Int(($0 * 100).rounded())) процентов" } ?? "")
    }
}

/// A share with a mark at the 50/30/20 guide.
private struct ShareBar: View {
    let share: Double
    let target: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule().fill(color).frame(width: max(8, geo.size.width * min(1, share)))
                RoundedRectangle(cornerRadius: 1).fill(Color.folkiInk.opacity(0.6))
                    .frame(width: 2, height: geo.size.height + 6)
                    .offset(x: geo.size.width * target - 1)
            }
        }.frame(height: 8).padding(.vertical, 3).accessibilityHidden(true)
    }
}
