import SwiftUI
import Charts
import FolkiDuoCore

struct BudgetAnalyticsSection: View {
    let session: BudgetSession
    let date: Date
    @State private var period: AnalyticsPeriod = .day
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var periodBudget: StoredBudget? {
        if let repository = session.repository { return try? repository.load(asOf: date, scope: session.scope) }
        return session.storedBudget
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Аналитика").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Picker("Период аналитики", selection: $period) {
                ForEach(AnalyticsPeriod.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if let result = try? BudgetAnalytics.calculate(records: session.historyRecords, period: period,
                anchor: date, asOf: session.referenceDate, calendar: session.calendar) {
                Text("\(session.scope.title) бюджет · по \(result.cutoff.formatted(.dateTime.day().month(.wide)))")
                    .font(.footnote).foregroundStyle(.secondary)
                if result.recordCount == 0 {
                    ContentUnavailableView("За этот период записей нет", systemImage: "chart.bar.xaxis",
                        description: Text("Добавьте расход или поступление, чтобы увидеть динамику."))
                } else {
                    totals(result)
                    chart(result).budgetCard()
                    if !result.categories.isEmpty { categories(result) }
                    if !result.contributionsByMember.isEmpty { contributions(result) }
                }
                if period == .month, let budget = periodBudget, budget.snapshot.period.contains(date),
                   let left = try? budget.snapshot.monthlyFreePlan.subtracting(result.flexibleNetSpending) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("До месячного лимита").font(.headline)
                        Text(MoneyText.string(left)).font(.title2.bold()).monospacedDigit()
                            .foregroundStyle(left.minorUnits < 0 ? Color.red : .primary)
                        Text("Свободные траты за вычетом возвратов. Лимит \(MoneyText.string(budget.snapshot.monthlyFreePlan)).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.budgetCard()
                }
                Text("Потрачено — расходы за вычетом возвратов, включая оплату из резервов. Переводы в накопления и взносы в семейный бюджет расходом не считаются.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Не удалось рассчитать аналитику", systemImage: "chart.bar.xaxis",
                    description: Text("Проверьте записи и попробуйте открыть раздел заново."))
            }
        }
    }

    private func totals(_ result: BudgetAnalyticsSnapshot) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 18) {
            total("Потрачено", (try? result.netSpending) ?? result.expenses)
            total("Поступления", result.income)
            if result.contributions.minorUnits > 0 {
                total(session.scope == .personal ? "В семейный бюджет" : "Взносы участников", result.contributions)
            }
            if result.reserveTransfers.minorUnits != 0 { total("В накопления", result.reserveTransfers) }
        }.budgetCard()
    }
    private func total(_ title: String, _ amount: Money) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MoneyText.string(amount)).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
    }
    private struct PlotPoint: Identifiable {
        let id: String
        let date: Date
        let value: Double
    }
    private func points(_ result: BudgetAnalyticsSnapshot) throws -> [PlotPoint] {
        try result.buckets.filter(\.isObserved).map { bucket in
            let spent = try bucket.expenses.subtracting(bucket.refunds)
            return PlotPoint(id: "\(bucket.start)", date: bucket.start, value: NSDecimalNumber(decimal: spent.decimalValue).doubleValue)
        }
    }
    @ViewBuilder private func chart(_ result: BudgetAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Траты по дням").font(.headline)
            if let points = try? points(result) {
                Chart(points) { point in
                    BarMark(x: .value("Дата", point.date, unit: period == .day ? .hour : .day), y: .value("Сумма", point.value))
                        .foregroundStyle(Color.folkiAccent)
                }
                .chartXScale(domain: result.interval.start...result.interval.end)
                .chartXAxis {
                    AxisMarks(values: .stride(by: period == .day ? .hour : .day, count: period == .day ? 6 : period == .month ? 7 : 1)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: period == .day ? .dateTime.hour() : period == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day())
                    }
                }
                .environment(\.calendar, session.calendar).environment(\.timeZone, session.calendar.timeZone)
                .frame(height: 180)
                .accessibilityLabel("Траты за период: \(MoneyText.string((try? result.netSpending) ?? result.expenses)).")
            }
        }
    }
    private func categories(_ result: BudgetAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("По категориям").font(.headline)
            ForEach(result.categories) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(item.category.title, systemImage: item.category.symbol)
                        Spacer()
                        Text(MoneyText.string(item.expenses)).monospacedDigit()
                    }.font(.subheadline)
                    if result.expenses.minorUnits > 0 {
                        ProgressView(value: Double(item.expenses.minorUnits) / Double(result.expenses.minorUnits)).tint(Color.folkiAccent)
                    }
                }
            }
        }.budgetCard()
    }
    private func contributions(_ result: BudgetAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Кто сколько внёс").font(.headline)
            ForEach(result.contributionsByMember) { item in
                HStack {
                    Label(session.memberName(item.memberID), systemImage: "person.fill")
                    Spacer()
                    Text(MoneyText.string(item.amount)).monospacedDigit()
                }.font(.subheadline)
            }
        }.budgetCard()
    }
}
