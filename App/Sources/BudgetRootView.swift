import SwiftUI
import FolkiDuoCore

private enum BudgetSheet: String, Identifiable {
    case spend, income, settings, distribution, allocate, sharing
    var id: String { rawValue }
}

struct BudgetRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var showsMonth = false
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var editingEntry: PeriodEntry?
    @State private var undoEntry: PeriodEntry?
    @State private var historyError: String?
    @State private var isRefreshing = false
    @State private var refreshPull: CGFloat = 0
    @State private var peakPull: CGFloat = 0
    /// A pull refreshes only when the drag began on the rings page already at the top,
    /// not when a swipe back from the history overshoots.
    @State private var pullArmed = false
    @State private var atTop = true
    @State private var refreshTask: Task<Void, Never>?
    @State private var selectedScope: BudgetScope = .personal
    private var session: BudgetSession { selectedScope == .personal ? personal : family }
    @State private var sheet: BudgetSheet?
    @State private var editingRecord: LedgerRecord?
    @Binding var selectedDay: Date?
    /// A `folki://spend` or `folki://add` link from a widget, Control Center or Shortcuts.
    @Binding var pendingEntry: URL?
    /// A plan exists once either budget has envelopes.
    private var planReady: Bool { !personal.envelopes.isEmpty || !family.envelopes.isEmpty }
    /// The first-spend hint appears once without moving either action button.
    @AppStorage("FolkiFirstSpendTip") private var firstSpendTip = false
    @State private var showsSpendTip = false
    @State private var spendTipDismissed = false
    @State private var tipHeight: CGFloat = 64
    @State private var rolled = true
    @Binding var inHistory: Bool
    var returnRequest: Int = 0
    /// Switches to the plan tab.
    var openPlan: () -> Void = {}
    /// "Позови семью" is offered once; envelopes in the amber zone can be dismissed until their next date.
    @AppStorage("FolkiInviteOfferDismissed") private var inviteDismissed = false
    @AppStorage("FolkiDismissedEnvelopeBanners") private var dismissedEnvelopes = ""
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
                                           isToday: selectedDay == nil, showsMonth: showsMonth, rolled: rolled,
                                           refreshing: isRefreshing, refreshPull: refreshPull / Self.refreshDistance,
                                           togglePeriod: toggleRingPeriod,
                                           showsFamily: family.household != nil,
                                           personalNeedsFunds: !personal.hasFunding, familyNeedsFunds: !family.hasFunding,
                                           addFunds: { scope in selectedScope = scope; sheet = .income }) { scope in
                    // The period is overspent: more money is the way back, not a smaller plan.
                    selectedScope = scope; sheet = .income
                }
                VStack(spacing: 8) {
                    weekCalendar.padding(.horizontal, FolkiSpacing.page)
                    GeometryReader { outer in
                    let bottomInset = outer.safeAreaInsets.bottom
                    GeometryReader { viewport in
                        // The page reaches under the tab bar, so the history stays out of sight until swiped up.
                        let page = viewport.size.height
                        ScrollView {
                            VStack(spacing: 0) {
                                VStack(spacing: 12) {
                                    if selectedDay == nil { banner }
                                    interactiveRings(card.rings).frame(maxHeight: .infinity)
                                    distributionLine
                                    entryArea(date: date, personalDay: personalDay, familyDay: familyDay)
                                    Button { scrollToHistory(page) } label: {
                                        Label("Траты за период", systemImage: "chevron.up")
                                            .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40)
                                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, FolkiSpacing.page)
                                .padding(.bottom, bottomInset)
                                .frame(height: page)
                                // The rings page recedes as the history scrolls over it.
                                .visualEffect { content, proxy in
                                    let progress = min(1, max(0, -proxy.frame(in: .scrollView).minY / max(1, page)))
                                    return content
                                        .scaleEffect(1 - progress * 0.12, anchor: .bottom)
                                        .opacity(1 - progress * 0.8)
                                }
                                VStack(spacing: FolkiSpacing.item) {
                                    PeriodHistoryList(personal: personal, family: family,
                                        edit: { editingEntry = $0 }, delete: deleteEntry, cancelContribution: cancelContribution)
                                }
                                .padding(.horizontal, FolkiSpacing.page).padding(.bottom, bottomInset + 40)
                                .frame(minHeight: page, alignment: .top)
                            }
                        }
                        .scrollIndicators(.never)
                        // No blurred band under the tab bar cutting into the list.
                        .scrollEdgeEffectHidden(true, for: .bottom)
                        .scrollTargetBehavior(RingsPageSnap(page: page))
                        .scrollPosition($scroll)
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            geometry.contentOffset.y + geometry.contentInsets.top >= page * 0.8
                        } action: { _, value in
                            if value != inHistory { inHistory = value }
                        }
                        .scrollBounceBehavior(.always)
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            geometry.contentOffset.y + geometry.contentInsets.top <= 2
                        } action: { _, value in atTop = value }
                        .onScrollGeometryChange(for: CGFloat.self) { geometry in
                            max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
                        } action: { _, value in
                            guard pullArmed, !isRefreshing, !inHistory else { return }
                            refreshPull = value
                            peakPull = max(peakPull, value)
                        }
                        .onScrollPhaseChange { old, new in
                            if new == .interacting && old != .interacting { pullArmed = atTop && !inHistory; peakPull = refreshPull }
                            if old == .interacting && new != .interacting {
                                if pullArmed && peakPull >= Self.refreshDistance && !isRefreshing && !inHistory {
                                    refreshTask = Task { await sync() }
                                }
                                peakPull = 0
                                pullArmed = false
                                withAnimation(FolkiMotion.quick) { refreshPull = 0 }
                            }
                        }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                    }
                    .overlay(alignment: .bottom) { undoToast }
                }.padding(.top, 4)

            }
            .background { FolkiBackground() }
            // A fixed title: the main screen scrolls into the history, and a collapsing large title would jump.
            .navigationTitle("Бюджет")
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Бюджет").font(.largeTitle.bold()).fixedSize().accessibilityAddTraits(.isHeader)
                }.sharedBackgroundVisibility(.hidden)
                headerActions
            }
            .onChange(of: pendingEntry, initial: true) { _, url in
                guard let url else { return }
                pendingEntry = nil
                selectedScope = .personal
                returnToToday { sheet = url.host == "add" ? .income : .spend }
            }
            .onChange(of: returnRequest) { _, _ in scrollToBudget() }
            .onAppear { FolkiFeedback.prepare() }
            .onDisappear { refreshTask?.cancel(); refreshPull = 0; peakPull = 0 }
        }
        .sheet(item: $editingRecord) { ExpenseEditorView(session: session, editing: $0) }
        .sheet(item: $editingEntry) { ExpenseEditorView(session: $0.session, editing: $0.record) }
        .alert("Запись не изменена", isPresented: Binding(get: { historyError != nil }, set: { if !$0 { historyError = nil } })) {
            Button("Готово") { historyError = nil }
        } message: { Text(historyError ?? "") }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .spend: QuickSpendView(personal: personal, family: family)
            case .income: DailyFundingView(personal: personal, family: family, initialScope: selectedScope)
            case .settings: BudgetSettingsView(personal: personal, family: family)
            case .sharing: SharingView(session: family)
            case .distribution:
                DistributionChoiceView(current: session.periodRule, apply: { try session.setPeriodRule($0) })
            case .allocate: DailyFundingView(personal: personal, family: family, initialScope: selectedScope, distributesExisting: true)
            }
        }
    }

    /// How far the rings must be pulled to sync: deliberately more than an overshoot.
    private static let refreshDistance: CGFloat = 120

    private func scrollToHistory(_ page: CGFloat) {
        withAnimation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion)) { scroll.scrollTo(y: page) }
    }

    private func scrollToBudget() {
        withAnimation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion)) { scroll.scrollTo(edge: .top) }
    }

    /// Pull down to refresh; all visual feedback belongs to the rings themselves.
    private func sync() async {
        guard !isRefreshing else { return }
        withAnimation(FolkiMotion.quick) { isRefreshing = true; refreshPull = 0 }
        defer { withAnimation(FolkiMotion.quick) { isRefreshing = false; refreshPull = 0 } }
        if let repository = personal.repository { await repository.verifyAccount() }
        do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
        personal.refresh(); family.refresh()
        FolkiFeedback.selection()
    }

    @ViewBuilder private var undoToast: some View {
        if let undoEntry {
            HStack(spacing: FolkiSpacing.item) {
                Text("Запись удалена").font(.subheadline)
                Spacer(minLength: 0)
                Button("Вернуть") { restore(undoEntry) }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, FolkiSpacing.page).frame(minHeight: 52)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.xs)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undoEntry.id) {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(FolkiMotion.standard) { self.undoEntry = nil }
            }
        }
    }

    private func deleteEntry(_ entry: PeriodEntry) {
        do {
            try entry.session.setDeleted(true, record: entry.record)
            FolkiFeedback.saved()
            withAnimation(FolkiMotion.standard) { undoEntry = entry }
        } catch { historyError = String(localized: "Не получилось изменить запись. Обнови историю и повтори.") }
    }
    private func restore(_ entry: PeriodEntry) {
        // The deleted record has a new revision; restore the stored one.
        let current = entry.session.deletedRecords.first { $0.id == entry.record.id } ?? entry.record
        do {
            try entry.session.setDeleted(false, record: current)
            FolkiFeedback.saved()
            withAnimation(FolkiMotion.standard) { undoEntry = nil }
        } catch { historyError = String(localized: "Не получилось вернуть запись. Попробуй ещё раз.") }
    }
    private func cancelContribution(_ entry: PeriodEntry) {
        do { try entry.session.cancelContribution(entry.record); FolkiFeedback.saved() }
        catch { historyError = String(localized: "Не получилось отменить взнос. Обнови историю и повтори.") }
    }

    /// "≈ 1 970 ₽/день до 19 нояб." — tap to change the period.
    private var distributionLine: some View {
        VStack(spacing: 6) {
            if personal.hasFunding, let result = personal.result, let end = personal.household?.period.endExclusive {
                let last = end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated))
                Button {
                    selectedScope = .personal; sheet = .distribution
                } label: {
                    Group {
                        // Past today's guide, the useful number is what tomorrow brings.
                        if result.todayRemaining.minorUnits < 0, let next = result.futureAllocation {
                            Text("Завтра ≈ \(MoneyText.whole(next.firstDayAmount.roundedDownToWholeUnits)) в день")
                        } else {
                            Text("≈ \(MoneyText.whole(result.todayGuide.roundedDownToWholeUnits))/день до \(last)")
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }.buttonStyle(.plain)
                if planReady, let guide = personal.plannedDailySpending {
                    Text("По плану ≈ \(MoneyText.whole(guide.roundedDownToWholeUnits))/день")
                        .font(.subheadline).foregroundStyle(Color.folkiAccent).monospacedDigit()
                }
                Button { selectedScope = .personal; sheet = .allocate } label: {
                    Text("На жизнь: \(MoneyText.whole(personal.availableForDailySpending))")
                        .font(.footnote.weight(.medium)).monospacedDigit()
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        // The first-spend hint sits over these lines; they step aside instead of showing through it.
        .opacity(showsSpendTip ? 0 : 1)
        .animation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion), value: showsSpendTip)
    }

    /// One banner at a time, by priority: a red envelope, an amber one, then the one-time family offer.
    @ViewBuilder private var banner: some View {
        // Every loud envelope competes, so dismissing one amber banner shows the next one, if any.
        let candidates = [personal, family].flatMap { session in
            session.envelopes.filter { session.envelopeUrgency($0) >= .attention }.map { (session, $0) }
        }.filter { !dismissed($0.1, in: $0.0) || $0.0.envelopeUrgency($0.1) == .serious }
        if let (session, envelope) = candidates.max(by: { $0.0.bannerRank($0.1) < $1.0.bannerRank($1.1) }) {
            envelopeBanner(envelope, in: session)
        } else if showsInviteOffer {
            HStack(spacing: FolkiSpacing.item) {
                Button { sheet = .sharing } label: {
                    Label {
                        Text("Ведёшь бюджет с кем-то? Позови — общее будет видно обоим").font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.leading)
                    } icon: { Image(systemName: "person.2.fill").foregroundStyle(RingPalette.family.start) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button { withAnimation(FolkiMotion.standard) { inviteDismissed = true } } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Скрыть")
            }
            .padding(.leading, FolkiSpacing.card).padding(.trailing, FolkiSpacing.xxs)
            .background(RingPalette.family.start.opacity(0.1), in: RoundedRectangle(cornerRadius: FolkiSpacing.controlRadius))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// From the third day with a budget, while there is no family yet.
    private var showsInviteOffer: Bool {
        guard !inviteDismissed, family.household == nil, personal.hasFunding,
              let first = personal.periods.first?.start else { return false }
        return (calendar.dateComponents([.day], from: calendar.startOfDay(for: first),
                                        to: calendar.startOfDay(for: personal.referenceDate)).day ?? 0) >= 2
    }

    private func bannerKey(_ envelope: RecurringEnvelope) -> String {
        "\(envelope.id.uuidString)@\(Int(envelope.nextDue.timeIntervalSince1970))"
    }
    private func dismissed(_ envelope: RecurringEnvelope, in session: BudgetSession) -> Bool {
        dismissedEnvelopes.split(separator: " ").contains { $0 == bannerKey(envelope) }
    }

    /// "Аренда: не хватает 12 000 ₽ к 25 окт." Red at 0–2 days stays; amber can be swiped away until the next date.
    private func envelopeBanner(_ envelope: RecurringEnvelope, in session: BudgetSession) -> some View {
        let urgency = session.envelopeUrgency(envelope)
        let missing = (try? envelope.shortfall(balance: session.envelopeBalance(envelope)).roundedUpToWholeUnits) ?? envelope.size
        let due = envelope.nextDue.formatted(.dateTime.day().month(.abbreviated))
        let tint = urgency == .serious ? Color.folkiOver : Color.folkiWarning
        return HStack(spacing: FolkiSpacing.item) {
            Button { selectedScope = session.scope; sheet = .allocate } label: {
                Label {
                    Text("\(envelope.name): не хватает \(MoneyText.whole(missing)) к \(due)").lineLimit(2)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: urgency == .serious ? "exclamationmark.circle.fill" : "clock.fill")
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            if urgency != .serious {
                Button {
                    withAnimation(FolkiMotion.standard) { dismissedEnvelopes = (dismissedEnvelopes + " " + bannerKey(envelope)).trimmingCharacters(in: .whitespaces) }
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Скрыть")
            }
        }
        .foregroundStyle(tint)
        .padding(.leading, FolkiSpacing.card).padding(.trailing, urgency == .serious ? FolkiSpacing.card : FolkiSpacing.xxs)
        .frame(minHeight: 48)
        .background(urgency == .serious ? Color.folkiOver.opacity(0.12) : Color.folkiWarningGround,
                    in: RoundedRectangle(cornerRadius: FolkiSpacing.controlRadius))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func toggleRingPeriod() {
        FolkiFeedback.selection()
        withAnimation(reduceMotion ? nil : FolkiMotion.ring) { showsMonth.toggle() }
    }

    private var isAtToday: Bool {
        calendar.isDate(selectedDay ?? session.referenceDate, inSameDayAs: session.referenceDate)
    }

    private func interactiveRings<Content: View>(_ content: Content) -> some View {
        content
            .accessibilityAction(named: Text("Обновить бюджет")) { refreshTask = Task { await sync() } }
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
        .animation(reduceMotion ? nil : FolkiMotion.quick, value: selectedDay == nil)
    }

    private var spendButton: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return GlassEffectContainer(spacing: 12) {
        layout {
            Button {
                dismissSpendTip()
                returnToToday {
                    sheet = .spend
                }
            } label: {
                Text("− Потратить").frame(maxWidth: .infinity).frame(minHeight: FolkiSpacing.primaryButton)
                    .foregroundStyle(.white)
                    .glassEffect(.regular.tint(Color.folkiAccent).interactive(), in: Capsule())
            }
            .buttonStyle(FolkiPressStyle())
            .frame(minWidth: 104, maxWidth: .infinity)
            // One sheet for every deposit; the family share and the family source live inside it.
            Button {
                returnToToday { selectedScope = .personal; sheet = .income }
            } label: {
                Text("+ Внести").frame(maxWidth: .infinity, minHeight: FolkiSpacing.primaryButton)
                    .glassEffect(.regular.interactive(), in: Capsule()).foregroundStyle(Color.folkiInk)
            }
            .buttonStyle(FolkiPressStyle())
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 140)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        }
        .font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.8).buttonStyle(.plain)
        }
        .overlay(alignment: .topLeading) {
            if showsSpendTip {
                Button(action: dismissSpendTip) {
                    HStack(alignment: .top, spacing: 10) {
                        Text("Запиши первую трату — покажу, как поменяется день")
                            .multilineTextAlignment(.leading)
                        Image(systemName: "xmark").font(.caption.weight(.semibold)).padding(.top, 3)
                    }
                        .font(.subheadline.weight(.medium)).foregroundStyle(Color.folkiBackground)
                        .padding(.horizontal, FolkiSpacing.card).padding(.vertical, FolkiSpacing.item)
                        .background(Color.folkiInk, in: RoundedRectangle(cornerRadius: FolkiSpacing.controlRadius))
                        .overlay(alignment: .bottomLeading) {
                            // The bubble's tail points at "Потратить".
                            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 14)).foregroundStyle(Color.folkiInk)
                                .offset(x: 48, y: 10)
                        }
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tipHeight = $0 }
                .offset(y: -tipHeight - 14)
                .transition(.scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity))
                .accessibilityHint("Скрыть подсказку")
            }
        }
        .task {
            guard firstSpendTip else { return }
            // Consume the offer once, including when the user leaves before it appears.
            firstSpendTip = false
            guard !personal.records.contains(where: { $0.transaction.kind == .expense }) else { return }
            do {
                try await Task.sleep(for: .milliseconds(1200))
                guard !spendTipDismissed, sheet == nil, selectedDay == nil else { return }
                try await Task.sleep(for: .milliseconds(300))
                guard !spendTipDismissed, sheet == nil, selectedDay == nil else { return }
                withAnimation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion)) { showsSpendTip = true }
                try await Task.sleep(for: .seconds(6))
                dismissSpendTip()
            } catch {
                showsSpendTip = false
            }
        }
        .onChange(of: sheet) { _, _ in dismissSpendTip() }
        .onChange(of: selectedDay) { _, _ in dismissSpendTip() }
    }

    private func dismissSpendTip() {
        spendTipDismissed = true
        firstSpendTip = false
        withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) { showsSpendTip = false }
    }

    private func returnToToday(then action: @escaping () -> Void = {}) {
        guard selectedDay != nil else { action(); return }
        if reduceMotion {
            selectedDay = nil
            action()
        } else {
            withAnimation(FolkiMotion.standard, completionCriteria: .logicallyComplete) {
                selectedDay = nil
            } completion: {
                action()
            }
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
    private var title: String {
        if !record.title.isEmpty { return record.title }
        if record.transaction.kind == .income { return String(localized: "Пополнение") }
        return session.category(for: record)?.name ?? ""
    }
    private var details: [String] {
        var parts = [session.payerName(for: record)]
        if record.transaction.kind != .income, let category = session.category(for: record) { parts.append(category.name) }
        if record.transaction.kind == .reserveAllocation { parts.append(String(localized: "В конверт")) }
        if showsDate { parts.append(record.transaction.date.formatted(.dateTime.day().month())) }
        return parts
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
                Text(title)
                Text(details.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            // Kopecks only when there are any.
            let amount = record.transaction.amount
            Text("\(prefix)\(amount.minorUnits % 100 == 0 ? MoneyText.whole(amount) : MoneyText.string(amount))").monospacedDigit()
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
            .folkiGlass(RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
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
                if family.household != nil { summary(family, overview: familyDay) }
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
