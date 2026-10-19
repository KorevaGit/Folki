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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
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
                        value(goals.isEmpty ? "—" : MoneyText.whole(goals.reduce(Money(minorUnits: 0)) { (try? $0.adding($1.balance)) ?? $0 }))
                        caption(goals.isEmpty ? "создай первую цель" : "\(goals.count) \(goals.count == 1 ? "цель" : "цели")")
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
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { FolkiFeedback.tap() })
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
    /// A whole week or month up to today, not cut at the selected day.
    private func periodEnd(_ period: AnalyticsPeriod, _ session: BudgetSession) -> Date {
        var calendar = session.calendar
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        guard let interval = calendar.dateInterval(of: period == .week ? .weekOfYear : .month, for: date) else { return date }
        return min(interval.end.addingTimeInterval(-1), session.referenceDate)
    }
    private func month(_ session: BudgetSession) -> BudgetAnalyticsSnapshot? {
        try? BudgetAnalytics.calculate(records: session.historyRecords, period: .month, anchor: periodEnd(.month, session),
                                       asOf: session.referenceDate, calendar: session.calendar, catalog: session.catalog)
    }
    private func week(_ session: BudgetSession) -> BudgetAnalyticsSnapshot? {
        try? BudgetAnalytics.calculate(records: session.historyRecords, period: .week, anchor: periodEnd(.week, session),
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
                FolkiSegmentedPicker(title: "Бюджет", selection: $scope,
                    options: BudgetScope.allCases.map { ($0.title, $0) }).padding(.horizontal, FolkiSpacing.page).padding(.vertical, 8)
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
                FolkiSegmentedPicker(title: "Бюджет", selection: Binding(get: { current }, set: { scope = $0 }),
                    options: BudgetScope.allCases.map { ($0.title, $0) })
                content(current == .personal ? personal : family).id(current)
            }.folkiPagePadding()
        }
        .background { FolkiBackground() }
        .navigationTitle(title).toolbarTitleDisplayMode(.inlineLarge)
        .safeAreaPadding(.bottom, 80)
        .toolbar(.visible, for: .navigationBar)
    }
}
