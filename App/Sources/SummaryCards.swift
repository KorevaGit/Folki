import SwiftUI
import FolkiDuoCore

/// Fitness-style summary: tiles with a headline number and a small chart, each opening its full screen.
struct SummaryCards: View {
    let personal: BudgetSession
    let family: BudgetSession
    let date: Date

    var body: some View {
        let personalMonth = month(personal), familyMonth = month(family)
        let personalWeek = week(personal)
        VStack(alignment: .leading, spacing: 12) {
            Text("Сводка").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                NavigationLink { ScopedScreen(personal: personal, family: family, title: "Аналитика") { BudgetAnalyticsSection(session: $0, date: date) } } label: {
                    tile("Сегодня", symbol: "flame.fill", tint: Color.budget(.personal)) {
                        value(spentToday(personal)); caption("семья \(spentToday(family))")
                    }
                }
                NavigationLink { ScopedScreen(personal: personal, family: family, title: "Аналитика") { BudgetAnalyticsSection(session: $0, date: date) } } label: {
                    tile("Неделя", symbol: "chart.bar.fill", tint: Color.budget(.personal)) {
                        value(personalWeek.map { MoneyText.whole((try? $0.netSpending) ?? $0.expenses) } ?? "—")
                        bars(personalWeek)
                    }
                }
                NavigationLink { ScopedScreen(personal: personal, family: family, title: "Аналитика") { BudgetAnalyticsSection(session: $0, date: date) } } label: {
                    tile("Категории", symbol: "square.grid.2x2.fill", tint: Color.folkiAccent) {
                        topCategories(personalMonth)
                    }
                }
                NavigationLink { ScopedScreen(personal: personal, family: family, title: "Накопления") { session in
                    VStack(spacing: 14) { SavingsSection(session: session) }
                } } label: {
                    tile("Накопления", symbol: "flag.fill", tint: Color.budget(.family)) {
                        let goals = personal.goals + family.goals
                        value(goals.isEmpty ? "Нет целей" : MoneyText.whole(goals.reduce(Money(minorUnits: 0)) { (try? $0.adding($1.balance)) ?? $0 }))
                        caption(goals.isEmpty ? "создай первую" : "\(goals.count) \(goals.count == 1 ? "цель" : "цели")")
                    }
                }
                NavigationLink { HistoryScreen(personal: personal, family: family) } label: {
                    tile("История", symbol: "clock.arrow.circlepath", tint: .secondary) {
                        let last = (personal.records + family.records).max { $0.transaction.date < $1.transaction.date }
                        value(last.map { MoneyText.whole($0.transaction.amount) } ?? "—")
                        caption(last.map { $0.title.isEmpty ? (personal.category(for: $0) ?? family.category(for: $0))?.name ?? "" : $0.title } ?? "записей пока нет")
                    }
                }
                NavigationLink { ScopedScreen(personal: personal, family: family, title: "Аналитика", initial: .family) { BudgetAnalyticsSection(session: $0, date: date) } } label: {
                    tile("Взносы", symbol: "person.2.fill", tint: Color.budget(.family)) {
                        value(familyMonth.map { MoneyText.whole($0.contributions) } ?? "—")
                        caption("за месяц")
                    }
                }
            }
        }
    }

    private func tile<Content: View>(_ title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption.bold())
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.tertiary)
            }.foregroundStyle(tint)
            content()
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .folkiGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .foregroundStyle(Color.folkiInk)
    }
    private func value(_ text: String) -> some View {
        Text(text).font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    private func bars(_ result: BudgetAnalyticsSnapshot?) -> some View {
        let values = (result?.buckets ?? []).map { max(0, Double($0.expenses.minorUnits - $0.refunds.minorUnits)) }
        let top = max(values.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { item in
                Capsule().fill(Color.budget(.personal).opacity(item.offset == values.count - 1 ? 1 : 0.55))
                    .frame(height: max(4, 30 * item.element / top))
            }
        }.frame(height: 30)
    }
    @ViewBuilder private func topCategories(_ result: BudgetAnalyticsSnapshot?) -> some View {
        let items = Array((result?.categories ?? []).prefix(3))
        if items.isEmpty { caption("пока без трат") }
        ForEach(items) { item in
            let category = personal.catalog.category(for: item.categoryID)
            HStack(spacing: 6) {
                CategoryIcon(category: category, size: 18)
                Text(category.name).font(.caption).lineLimit(1)
                Spacer(minLength: 2)
                Text(MoneyText.whole(item.expenses)).font(.caption.weight(.semibold)).monospacedDigit()
            }
        }
    }

    private func spentToday(_ session: BudgetSession) -> String {
        session.overview(on: date).result.map { MoneyText.whole($0.todayNetSpending.roundedUpToWholeUnits) } ?? "—"
    }
    private func month(_ session: BudgetSession) -> BudgetAnalyticsSnapshot? {
        try? BudgetAnalytics.calculate(records: session.historyRecords, period: .month, anchor: date,
                                       asOf: session.referenceDate, calendar: session.calendar, catalog: session.catalog)
    }
    private func week(_ session: BudgetSession) -> BudgetAnalyticsSnapshot? {
        try? BudgetAnalytics.calculate(records: session.historyRecords, period: .week, anchor: date,
                                       asOf: session.referenceDate, calendar: session.calendar, catalog: session.catalog)
    }
}

/// History is a List, so the switch sits above it instead of inside a scroll view.
struct HistoryScreen: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var scope: BudgetScope = .personal
    var body: some View {
        BudgetHistoryView(session: scope == .personal ? personal : family).id(scope)
            .safeAreaInset(edge: .top) {
                Picker("Бюджет", selection: $scope) { ForEach(BudgetScope.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 8).background(.bar)
            }
            .toolbar(.visible, for: .navigationBar)
    }
}

/// A detail screen with the personal/family switch, which no longer sits on the main screen.
struct ScopedScreen<Content: View>: View {
    let personal: BudgetSession
    let family: BudgetSession
    let title: String
    var initial: BudgetScope = .personal
    @ViewBuilder let content: (BudgetSession) -> Content
    @State private var scope: BudgetScope?

    var body: some View {
        let current = scope ?? initial
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Бюджет", selection: Binding(get: { current }, set: { scope = $0 })) {
                    ForEach(BudgetScope.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                content(current == .personal ? personal : family).id(current)
            }.padding(20)
        }
        .background { FolkiBackground() }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
