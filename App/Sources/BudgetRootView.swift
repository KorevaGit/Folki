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
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var editingEntry: PeriodEntry?
    @State private var undoEntry: PeriodEntry?
    @State private var historyError: String?
    /// Shown under the rings for a moment after pulling down.
    @State private var syncStatus: String?
    @State private var selectedScope: BudgetScope = .personal
    private var session: BudgetSession { selectedScope == .personal ? personal : family }
    @State private var sheet: BudgetSheet?
    @State private var editingRecord: LedgerRecord?
    @Binding var selectedDay: Date?
    /// Switches to the plan tab.
    var openPlan: () -> Void = {}
    @AppStorage("FolkiPlanReady") private var planReady = false
    @AppStorage("FolkiPlanOfferDismissed") private var planOfferDismissed = false
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
                        let page = viewport.size.height
                        ScrollView {
                            VStack(spacing: 0) {
                                VStack(spacing: 12) {
                                    if selectedDay == nil { banner }
                                    interactiveRings(card.rings).frame(maxHeight: .infinity)
                                    syncCaption
                                    distributionLine
                                    entryArea(date: date, personalDay: personalDay, familyDay: familyDay)
                                    Button { scrollToHistory(page) } label: {
                                        Label("Траты за период", systemImage: "chevron.down")
                                            .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40)
                                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, FolkiSpacing.page)
                                .frame(height: page)
                                // The rings page recedes as the history scrolls over it.
                                .visualEffect { content, proxy in
                                    let progress = min(1, max(0, -proxy.frame(in: .scrollView).minY / max(1, page)))
                                    return content
                                        .scaleEffect(1 - progress * 0.12, anchor: .bottom)
                                        .opacity(1 - progress * 0.8)
                                }
                                PeriodHistoryList(personal: personal, family: family,
                                    edit: { editingEntry = $0 }, delete: deleteEntry, cancelContribution: cancelContribution)
                                    .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.huge)
                                    .frame(minHeight: page, alignment: .top)
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollTargetBehavior(RingsPageSnap(page: page))
                        .scrollPosition($scroll)
                        .refreshable { await sync() }
                    }
                    .overlay(alignment: .bottom) { undoToast }
                }.padding(.top, 4).padding(.bottom, 8)

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
            .onAppear { FolkiFeedback.prepare() }
        }
        .sheet(item: $editingRecord) { ExpenseEditorView(session: session, editing: $0) }
        .sheet(item: $editingEntry) { ExpenseEditorView(session: $0.session, editing: $0.record) }
        .alert("Запись не изменена", isPresented: Binding(get: { historyError != nil }, set: { if !$0 { historyError = nil } })) {
            Button("Готово") { historyError = nil }
        } message: { Text(historyError ?? "") }
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

    private func scrollToHistory(_ page: CGFloat) {
        FolkiFeedback.selection()
        withAnimation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion)) { scroll.scrollTo(y: page) }
    }

    /// Pull down: ask iCloud again and reload both budgets.
    private func sync() async {
        if let repository = personal.repository { await repository.verifyAccount() }
        try? await Task.sleep(for: .milliseconds(500))
        personal.refresh(); family.refresh()
        FolkiFeedback.selection()
        withAnimation(FolkiMotion.standard) {
            syncStatus = personal.repository?.statusText ?? String(localized: "Обновлено")
        }
        // The caption outlives the spinner, so it is cleared by its own task.
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(FolkiMotion.standard) { syncStatus = nil }
        }
    }

    @ViewBuilder private var syncCaption: some View {
        if let syncStatus {
            Label(syncStatus, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary).transition(.opacity)
        }
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
        Group {
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
            }
        }
    }

    /// One banner at a time: a short envelope first, then the plan offer.
    @ViewBuilder private var banner: some View {
        if [personal, family].contains(where: { $0.mostUrgentEnvelope != nil }) {
            envelopeBanner
        } else if !planReady && !planOfferDismissed && personal.hasFunding {
            HStack(spacing: FolkiSpacing.item) {
                Button(action: openPlan) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Учесть аренду и подписки?").font(.subheadline.weight(.semibold))
                            Text("Составь финансовый план").font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "list.bullet.clipboard").foregroundStyle(Color.folkiAccent) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button { withAnimation(FolkiMotion.standard) { planOfferDismissed = true } } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).frame(width: 32, height: 32)
                }.buttonStyle(.plain).accessibilityLabel("Скрыть")
            }
            .padding(.vertical, FolkiSpacing.xs).padding(.leading, FolkiSpacing.card).padding(.trailing, FolkiSpacing.xs)
            .background(Color.folkiAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The most urgent short envelope of either budget: red at 0–2 days, amber at 3–7.
    @ViewBuilder private var envelopeBanner: some View {
        let candidates = [personal, family].compactMap { session in session.mostUrgentEnvelope.map { (session, $0) } }
        if let (session, envelope) = candidates.max(by: { session0, session1 in
            (session0.0.envelopeUrgency(session0.1), -session0.0.daysUntil(session0.1)) < (session1.0.envelopeUrgency(session1.1), -session1.0.daysUntil(session1.1))
        }) {
            let urgency = session.envelopeUrgency(envelope)
            let missing = (try? envelope.shortfall(balance: session.envelopeBalance(envelope)).roundedUpToWholeUnits) ?? envelope.size
            let due = envelope.nextDue.formatted(.dateTime.day().month(.abbreviated))
            Label {
                // "Аренда — 12 000 ₽ до 25 окт.": what is still missing and by when.
                Text("\(envelope.name) — \(MoneyText.whole(missing)) до \(due)").lineLimit(2)
            } icon: {
                Image(systemName: urgency == .serious ? "exclamationmark.circle.fill" : "clock.fill")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(urgency == .serious ? Color.red : Color.folkiWarning)
            .padding(.vertical, FolkiSpacing.item).padding(.horizontal, FolkiSpacing.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(urgency == .serious ? Color.red.opacity(0.12) : Color.folkiWarningGround, in: RoundedRectangle(cornerRadius: 16))
            .transition(.move(edge: .top).combined(with: .opacity))
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
