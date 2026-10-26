import SwiftUI
import FolkiDuoCore

private enum BudgetSheet: String, Identifiable {
    case spend, income, settings, distribution, allocate, sharing, summary
    var id: String { rawValue }
}

struct BudgetRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var showsMonth = false
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var editingEntry: PeriodEntry?
    @State private var undoEntry: PeriodEntry?
    /// The toast offers to take back a spend just recorded, not to restore a deleted one.
    @State private var undoIsNewSpend = false
    @State private var historyError: String?
    @State private var isRefreshing = false
    @State private var refreshPull: CGFloat = 0
    @State private var peakPull: CGFloat = 0
    /// A pull refreshes only when the drag began on the rings page already at the top,
    /// not when a swipe back from the history overshoots.
    @State private var pullArmed = false
    @State private var atTop = true
    /// Height the banner takes, zero without one; the rings give it exactly that much room.
    @State private var bannerHeight: CGFloat = 0
    @State private var refreshTask: Task<Void, Never>?
    @State private var selectedScope: BudgetScope = .personal
    private var session: BudgetSession { selectedScope == .personal ? personal : family }
    @State private var sheet: BudgetSheet?
    @State private var editingRecord: LedgerRecord?
    @Binding var selectedDay: Date?
    /// A `folki://spend` or `folki://add` link from a widget, Control Center or Shortcuts.
    @Binding var pendingEntry: URL?
    /// The first-spend hint appears once without moving either action button.
    @AppStorage("FolkiFirstSpendTip") private var firstSpendTip = false
    @State private var showsSpendTip = false
    /// The lines under the hint leave first, so the two never show through each other.
    @State private var clearingForTip = false
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
    @AppStorage("FolkiSeenPeriodSummary") private var seenSummary = 0.0
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
                                           addFunds: { scope in selectedScope = scope; sheet = .income },
                                           // In the hierarchy, not as `card.rings`: only then it reads text size and Reduce Motion.
                                           ringsOnly: true) { scope in
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
                                    // A past day keeps the banner's place, so switching days never moves the ring.
                                    banner.opacity(selectedDay == nil ? 1 : 0).allowsHitTesting(selectedDay == nil)
                                        .accessibilityHidden(selectedDay != nil)
                                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
                                    // One diameter for every day, and the free space sits above the bottom block:
                                    // a past day's summary in place of the buttons moves neither the ring nor the line under it.
                                    if dynamicTypeSize.isAccessibilitySize {
                                        interactiveRings(card).frame(maxHeight: .infinity)
                                        distributionLine
                                    } else {
                                        interactiveRings(card)
                                            .frame(width: ringSide(viewport.size, page: page), height: ringSide(viewport.size, page: page))
                                            .frame(maxWidth: .infinity)
                                        distributionLine
                                        Spacer(minLength: 0)
                                    }
                                    entryArea(date: date, personalDay: personalDay, familyDay: familyDay)
                                    Button { scrollToHistory(page) } label: {
                                        // A grabber, like a sheet's; the words only in the first days.
                                        Group {
                                            if showsHistoryLabel {
                                                Label("Траты за период", systemImage: "chevron.down.2").font(FolkiFont.label)
                                            } else {
                                                Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 36, height: 5)
                                            }
                                        }.frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
                                    }.buttonStyle(.plain).foregroundStyle(Color.folkiSecondary).accessibilityLabel("Траты за период")
                                }
                                .padding(.horizontal, FolkiSpacing.page)
                                .padding(.bottom, bottomInset)
                                // Anchored to the top: if the page is ever a little too tall, the grabber yields, not the banner.
                                .frame(height: page, alignment: .top)
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
                    Text("Бюджет").font(FolkiFont.title).fixedSize().accessibilityAddTraits(.isHeader)
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
        .sheet(item: $editingEntry) { entry in
            // An own everyday spend opens in the spend sheet; incomes, refunds and envelope spends keep the full form.
            if entry.record.transaction.kind == .expense, entry.record.transaction.funding == .flexible,
               entry.session.isEditable(entry.record) {
                QuickSpendView(editing: entry.record, in: entry.session, personal: personal, family: family) { record, session in
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        deleteEntry(PeriodEntry(record: record, session: session))
                    }
                }
            } else {
                ExpenseEditorView(session: entry.session, editing: entry.record)
            }
        }
        .alert("Запись не изменена", isPresented: Binding(get: { historyError != nil }, set: { if !$0 { historyError = nil } })) {
            Button("Готово") { historyError = nil }
        } message: { Text(historyError ?? "") }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .spend: QuickSpendView(personal: personal, family: family, onRecorded: { record, session in
                // After the sheet has gone, so the toast does not slide in under it.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(FolkiMotion.standard) { undoIsNewSpend = true; undoEntry = PeriodEntry(record: record, session: session) }
                }
            })
            case .income: DailyFundingView(personal: personal, family: family, initialScope: selectedScope)
            case .settings: BudgetSettingsView(personal: personal, family: family)
            case .sharing: SharingView(session: family)
            case .summary:
                if let period = personal.finishedPeriod {
                    PeriodSummaryView(session: personal, period: period) {
                        selectedScope = .personal
                        Task { try? await Task.sleep(for: .milliseconds(450)); sheet = .income }
                    }
                }
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
                Text(undoIsNewSpend ? String(localized: "Записано \(MoneyText.whole(undoEntry.record.transaction.amount))")
                     : String(localized: "Запись удалена")).font(FolkiFont.caption).monospacedDigit()
                Spacer(minLength: 0)
                Button(undoIsNewSpend ? String(localized: "Отменить") : String(localized: "Вернуть")) {
                    undoIsNewSpend ? takeBack(undoEntry) : restore(undoEntry)
                }.font(FolkiFont.label)
            }
            .padding(.horizontal, FolkiSpacing.page).frame(minHeight: 52)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.xs)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undoEntry.id) {
                // A new spend gets longer: first the figure is read, then the mistake is noticed.
                try? await Task.sleep(for: .seconds(undoIsNewSpend ? 6 : 4))
                withAnimation(FolkiMotion.standard) { self.undoEntry = nil }
            }
        }
    }

    private func deleteEntry(_ entry: PeriodEntry) {
        do {
            try entry.session.setDeleted(true, record: entry.record)
            FolkiFeedback.saved()
            withAnimation(FolkiMotion.standard) { undoIsNewSpend = false; undoEntry = entry }
        } catch { historyError = String(localized: "Не получилось изменить запись. Обнови историю и повтори.") }
    }
    /// A spend recorded by mistake: deleted at once, with no second toast.
    private func takeBack(_ entry: PeriodEntry) {
        do {
            try entry.session.setDeleted(true, record: entry.record)
            FolkiFeedback.saved()
            withAnimation(FolkiMotion.standard) { undoEntry = nil }
        } catch { historyError = String(localized: "Не получилось отменить трату. Удали её в истории.") }
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
        VStack(spacing: FolkiSpacing.xs) {
            if personal.hasFunding, let result = personal.result, let end = personal.household?.period.endExclusive {
                let last = end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated))
                Button {
                    selectedScope = .personal; sheet = .distribution
                } label: {
                    Group {
                        // Past today's guide, the useful number is what tomorrow brings.
                        if result.todayRemaining.minorUnits < 0, let next = result.futureAllocation {
                            Text("Завтра ≈ \(MoneyText.whole(next.firstDayAmount.roundedDownToWholeUnits)) в день")
                        } else if let outlook = personal.obligationsOutlook {
                            // Unpaid bills of this period come out of the same money, so the forecast counts them.
                            switch outlook {
                            case .guide(let guide):
                                Text("С платежами ≈ \(MoneyText.whole(guide.roundedDownToWholeUnits))/день до \(last)")
                            case .short(let missing):
                                Text("На платежи не хватает \(MoneyText.whole(missing.roundedUpToWholeUnits))")
                                    .foregroundStyle(Color.folkiOver)
                            }
                        } else {
                            Text("≈ \(MoneyText.whole(result.todayGuide.roundedDownToWholeUnits))/день до \(last)")
                        }
                    }
                    .folkiText(.caption).monospacedDigit()
                    // Large text wraps the line instead of cutting off the date.
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain)
            }
        }
        // The first-spend hint sits over these lines; they step aside instead of showing through it.
        .opacity(showsSpendTip || clearingForTip ? 0 : 1)
        .animation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion), value: showsSpendTip || clearingForTip)
    }

    /// One banner at a time, by priority: a red envelope, an amber one, then the one-time family offer.
    @ViewBuilder private var banner: some View {
        // Every loud envelope competes, so dismissing one amber banner shows the next one, if any.
        let candidates = [personal, family].flatMap { session in
            session.envelopes.filter { session.envelopeUrgency($0) >= .attention }.map { (session, $0) }
        }.filter { !dismissed($0.1, in: $0.0) || $0.0.envelopeUrgency($0.1) == .serious }
        let loudest = candidates.max(by: { $0.0.bannerRank($0.1) < $1.0.bannerRank($1.1) })
        if let (session, envelope) = loudest, session.envelopeUrgency(envelope) == .serious {
            envelopeBanner(envelope, in: session)
        } else if let finished = personal.finishedPeriod, seenSummary != finished.start.timeIntervalSince1970 {
            periodBanner(finished)
        } else if let (session, envelope) = loudest {
            envelopeBanner(envelope, in: session)
        } else if showsInviteOffer {
            HStack(spacing: FolkiSpacing.item) {
                Button { sheet = .sharing } label: {
                    Label {
                        Text("Ведёшь бюджет с кем-то? Позови").font(FolkiFont.label)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "person.2.fill").foregroundStyle(Color.folkiFamily) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button { withAnimation(FolkiMotion.standard) { inviteDismissed = true } } label: {
                    Image(systemName: "xmark").font(FolkiFont.label).foregroundStyle(Color.folkiSecondary).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Скрыть")
            }
            .padding(.leading, FolkiSpacing.card).padding(.trailing, FolkiSpacing.xxs)
            .background(Color.folkiFamily.opacity(0.1), in: RoundedRectangle(cornerRadius: FolkiSpacing.controlRadius))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// "Период закончился": the new one started on its own; the results open only on a tap.
    private func periodBanner(_ period: BudgetPeriod) -> some View {
        HStack(spacing: FolkiSpacing.item) {
            Button { seenSummary = period.start.timeIntervalSince1970; sheet = .summary } label: {
                Label {
                    Text("Период закончился, новый уже идёт. Посмотреть итоги").font(FolkiFont.label)
                        .multilineTextAlignment(.leading)
                } icon: { Image(systemName: "calendar.badge.checkmark").foregroundStyle(Color.folkiAccent) }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button { withAnimation(FolkiMotion.standard) { seenSummary = period.start.timeIntervalSince1970 } } label: {
                Image(systemName: "xmark").font(FolkiFont.label).foregroundStyle(Color.folkiSecondary).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("Скрыть")
        }
        .padding(.leading, FolkiSpacing.card).padding(.trailing, FolkiSpacing.xxs)
        .background(Color.folkiAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: FolkiSpacing.controlRadius))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// The history hint is spelled out during the first three days with a budget.
    private var showsHistoryLabel: Bool {
        guard let first = personal.periods.first?.start else { return true }
        return (calendar.dateComponents([.day], from: calendar.startOfDay(for: first),
                                        to: calendar.startOfDay(for: personal.referenceDate)).day ?? 0) < 3
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
                    // What, how much is missing, by when — a shortfall, not a charge.
                    Text(session.daysUntil(envelope) <= 0
                         ? String(localized: "\(envelope.name): сегодня не хватает \(MoneyText.whole(missing))")
                         : String(localized: "\(envelope.name): не хватает \(MoneyText.whole(missing)) к \(due)"))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2).minimumScaleFactor(0.9)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: urgency == .serious ? "exclamationmark.circle.fill" : "clock.fill")
                }
                .font(FolkiFont.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            if urgency != .serious {
                Button {
                    withAnimation(FolkiMotion.standard) { dismissedEnvelopes = (dismissedEnvelopes + " " + bannerKey(envelope)).trimmingCharacters(in: .whitespaces) }
                } label: {
                    Image(systemName: "xmark").font(FolkiFont.label).frame(width: 44, height: 44)
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

    /// The rings' diameter from the page alone: the width between margins, capped by 60 % of the page height.
    private func ringSide(_ size: CGSize, page: CGFloat) -> CGFloat {
        // A banner keeps the same height on every day, so it shrinks the rings once, not on each switch.
        // The banner, its spacing and a little air, so a two-line banner never presses on the calendar.
        let banner = bannerHeight > 0 ? bannerHeight + 24 : 0
        return max(160, min(size.width - 2 * FolkiSpacing.page, page * 0.6 - banner))
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
        } overspent: { day in
            (personal.overview(on: day).result?.todayRemaining.minorUnits ?? 0) < 0
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
                VStack(spacing: FolkiSpacing.item) {
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
        .font(FolkiFont.moneyCard).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.8).buttonStyle(.plain)
        }
        .overlay(alignment: .topLeading) {
            if showsSpendTip {
                Button(action: dismissSpendTip) {
                    HStack(alignment: .top, spacing: FolkiSpacing.item) {
                        Text("Запиши первую трату — покажу, как поменяется день")
                            .multilineTextAlignment(.leading)
                        Image(systemName: "xmark").font(FolkiFont.tag).padding(.top, FolkiSpacing.xxs)
                    }
                        .font(FolkiFont.label).foregroundStyle(Color.folkiBackground)
                        .padding(.horizontal, FolkiSpacing.card).padding(.vertical, FolkiSpacing.item)
                        .background(Color.folkiInk, in: RoundedRectangle(cornerRadius: FolkiSpacing.controlRadius))
                        .overlay(alignment: .bottomLeading) {
                            // The bubble's tail points at "Потратить".
                            Image(systemName: "arrowtriangle.down.fill").font(FolkiFont.symbol(14)).foregroundStyle(Color.folkiInk)
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
                clearingForTip = true
                try await Task.sleep(for: .milliseconds(250))
                withAnimation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion)) { showsSpendTip = true }
                try await Task.sleep(for: .seconds(6))
                dismissSpendTip()
            } catch {
                showsSpendTip = false; clearingForTip = false
            }
        }
        .onChange(of: sheet) { _, _ in dismissSpendTip() }
        .onChange(of: selectedDay) { _, _ in dismissSpendTip() }
    }

    private func dismissSpendTip() {
        spendTipDismissed = true
        firstSpendTip = false
        withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) { showsSpendTip = false }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            clearingForTip = false
        }
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
        var parts: [String] = []
        // "Я" says nothing when no one else keeps this budget.
        if session.members.filter(\.isActive).count > 1 { parts.append(session.payerName(for: record)) }
        // The category is already the title when there is no description.
        if record.transaction.kind != .income, !record.title.isEmpty, let category = session.category(for: record) { parts.append(category.name) }
        if record.transaction.kind == .reserveAllocation { parts.append(String(localized: "В конверт")) }
        parts.append(showsDate ? record.transaction.date.formatted(.dateTime.day().month())
                               : record.transaction.date.formatted(date: .omitted, time: .shortened))
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title).folkiText(.body)
                Text(details.joined(separator: " · ")).folkiText(.footnote)
            }
            Spacer(minLength: 4)
            // Kopecks only when there are any.
            let amount = record.transaction.amount
            Text("\(prefix)\(amount.minorUnits % 100 == 0 ? MoneyText.whole(amount) : MoneyText.string(amount))")
                .font(FolkiFont.moneyRow).monospacedDigit().foregroundStyle(Color.folkiInk)
                .lineLimit(1).minimumScaleFactor(0.65).layoutPriority(1)
        }.padding(.vertical, FolkiSpacing.item)
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

/// A past day under the rings: what the money went on and what that day did to every day after it.
/// One row per budget; the ring above already says how much was spent.
private struct BudgetDaySpendingSummary: View {
    let date: Date
    let personal: BudgetSession
    let family: BudgetSession
    let personalDay: BudgetDayOverview
    let familyDay: BudgetDayOverview

    var body: some View {
        // Exactly the height of the buttons it replaces, so nothing above it moves when the day changes.
        VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
            row(personal, overview: personalDay)
            if family.household != nil { row(family, overview: familyDay) }
        }
        .frame(maxWidth: .infinity, minHeight: FolkiSpacing.primaryButton, maxHeight: FolkiSpacing.primaryButton, alignment: .center)
    }

    @ViewBuilder private func row(_ session: BudgetSession, overview: BudgetDayOverview) -> some View {
        let analytics = try? BudgetAnalytics.calculate(records: overview.records, period: .day, anchor: date,
            asOf: session.referenceDate, calendar: session.calendar, catalog: session.catalog)
        let parts = (analytics?.categories ?? []).filter { $0.expenses.minorUnits > 0 }
            .sorted { $0.expenses.minorUnits > $1.expenses.minorUnits }
        HStack(spacing: FolkiSpacing.xs) {
            Circle().fill(session.scope == .personal ? Color.folkiPersonal : Color.folkiFamily).frame(width: 8, height: 8)
                .accessibilityLabel(session.scope.title)
            if parts.isEmpty {
                Image(systemName: "checkmark").font(FolkiFont.label).foregroundStyle(Color.folkiTertiary)
                    .accessibilityLabel("Трат не было")
            }
            // The two biggest categories; the rest are counted, not listed.
            ForEach(parts.prefix(2)) { part in
                let category = session.catalog.category(for: part.categoryID)
                HStack(spacing: 6) {
                    CategoryIcon(category: category, size: 22)
                    Text(MoneyText.whole(part.expenses)).font(FolkiFont.moneySmall).monospacedDigit().foregroundStyle(Color.folkiInk)
                }
                .padding(.leading, 2).padding(.trailing, FolkiSpacing.item).frame(height: 28)
                .background(Color.folkiTile, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(category.name), \(MoneyText.whole(part.expenses))")
            }
            if parts.count > 2 {
                Text("+\(parts.count - 2)").font(FolkiFont.label).foregroundStyle(Color.folkiSecondary)
            }
            Spacer(minLength: FolkiSpacing.xs)
            if let effect = effect(overview.result) { consequence(effect) }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
    }

    /// How that day moved every following day of the period: what it left or overspent, spread over the days after it.
    private func effect(_ result: DailyBudgetSnapshot?) -> Money? {
        guard let result, result.remainingDays > 1 else { return nil }
        let perDay = result.todayRemaining.minorUnits / Int64(result.remainingDays - 1)
        return abs(perDay) < 100 ? nil : Money(minorUnits: perDay)
    }

    private func consequence(_ perDay: Money) -> some View {
        let gain = perDay.minorUnits > 0
        return HStack(spacing: 4) {
            Image(systemName: "arrow.forward").font(FolkiFont.tag)
            Text((gain ? "+" : "−") + MoneyText.whole(Money(minorUnits: abs(perDay.minorUnits))))
                .font(FolkiFont.moneySmall).monospacedDigit()
            Text("/день").font(FolkiFont.footnote)
        }
        .foregroundStyle(gain ? Color.folkiAccent : Color.folkiOver)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gain ? String(localized: "Каждый следующий день стал больше на \(MoneyText.whole(perDay))")
            : String(localized: "Каждый следующий день стал меньше на \(MoneyText.whole(Money(minorUnits: -perDay.minorUnits)))"))
    }
}
