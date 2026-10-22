import SwiftUI
import UIKit
import UserNotifications
import FolkiDuoCore

/// "План": regular payments, reminders and the family share. Until it is set up the tab is a short
/// onboarding-style walk-through; afterwards each part is edited on its own.
struct PlanTab: View {
    let personal: BudgetSession
    let family: BudgetSession
    /// An envelope a widget asked to open.
    @Binding var pendingEnvelope: UUID?
    /// The wizard is open over the tab: keep the page under it until it closes.
    @State private var editing = false
    @State private var frozen: Bool?
    @State private var distributeAfterWizard = false
    @State private var distributing = false
    /// A plan exists when either budget has envelopes; the data decides, not a flag on this iPhone.
    private var hasPlan: Bool { !personal.envelopes.isEmpty || !family.envelopes.isEmpty }

    var body: some View {
        Group {
            if frozen ?? hasPlan {
                PlanOverview(personal: personal, family: family, pendingEnvelope: $pendingEnvelope, wizardOpen: $editing,
                             saved: { distributeAfterWizard = $0 }, closed: wizardClosed)
            } else {
                PlanIntro(personal: personal, family: family, settingUp: $editing,
                          saved: { distributeAfterWizard = $0 }, closed: wizardClosed)
            }
        }
        .animation(FolkiMotion.standard, value: frozen ?? hasPlan)
        .onChange(of: editing) { _, open in if open { frozen = hasPlan } }
        .sheet(isPresented: $distributing) {
            DailyFundingView(personal: personal, family: family, distributesExisting: true)
        }
    }

    /// One thing at a time: the wizard closes, then the page changes, then the distribution is offered.
    private func wizardClosed() {
        withAnimation(FolkiMotion.standard) { frozen = nil }
        guard distributeAfterWizard else { return }
        distributeAfterWizard = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            distributing = true
        }
    }
}

// MARK: - Intro

/// The tab before a plan exists: one welcome, the setup opens over it and can be left at any step.
private struct PlanIntro: View {
    let personal: BudgetSession
    let family: BudgetSession
    @Binding var settingUp: Bool
    let saved: (Bool) -> Void
    let closed: () -> Void
    @Namespace private var zoom
    var body: some View {
        OnboardingPage(centered: true) {
            VStack(spacing: FolkiSpacing.large) {
                PlanHeroArt().frame(maxWidth: 340).rise(0)
                VStack(spacing: FolkiSpacing.item) {
                    Text("Финансовый план").font(.largeTitle.bold()).rise(1)
                    Text("Учту аренду, связь и подписки — и они не съедят деньги на жизнь")
                        .font(.body).foregroundStyle(.secondary).rise(2)
                }.multilineTextAlignment(.center)
            }.padding(.bottom, FolkiSpacing.huge)
        } actions: {
            Button("Составить план") { settingUp = true }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                .matchedTransitionSource(id: "plan", in: zoom).rise(3)
        }
        .padding(.bottom, FolkiSpacing.item)
        .background { FolkiBackground() }
        .fullScreenCover(isPresented: $settingUp, onDismiss: closed) {
            NavigationStack {
                PlanWizardView(personal: personal, family: family, startsWithHello: false,
                               finish: { saved($0); settingUp = false }, cancel: { settingUp = false })
                    .toolbar(.hidden, for: .navigationBar)
            }
            .navigationTransition(.zoom(sourceID: "plan", in: zoom))
        }
    }
}

struct PlanHeroArt: View {
    @State private var split = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let parts: [(LocalizedStringKey, Int64, Color)] = [
        ("Аренда", 25_000, Color(red: 0.62, green: 0.42, blue: 0.24)),
        ("Связь", 800, Color(red: 0.30, green: 0.56, blue: 0.86)),
        ("Подписки", 1_200, Color(red: 0.55, green: 0.40, blue: 0.85)),
        ("На жизнь", 53_000, Color.folkiAccent)
    ]
    private var total: Int64 { parts.reduce(0) { $0 + $1.1 } }

    var body: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.item) {
            HStack(alignment: .firstTextBaseline) {
                Text("Зарплата").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(MoneyText.whole(Money(minorUnits: total * 100))).font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
            }
            GeometryReader { geo in
                let gaps = CGFloat(parts.count - 1) * 3
                HStack(spacing: split ? 3 : 0) {
                    ForEach(parts.indices, id: \.self) { index in
                        let part = parts[index]
                        let last = index == parts.count - 1
                        RoundedRectangle(cornerRadius: 6)
                            .fill(split || last ? part.2 : Color.folkiAccent)
                            .frame(width: split
                                ? max(6, (geo.size.width - gaps) * CGFloat(part.1) / CGFloat(total))
                                : (last ? geo.size.width : 0))
                    }
                }
            }.frame(height: 22)
            VStack(spacing: FolkiSpacing.xs) {
                ForEach(parts.indices, id: \.self) { index in
                    let part = parts[index]
                    HStack(spacing: FolkiSpacing.xs) {
                        Circle().fill(part.2).frame(width: 10, height: 10)
                        Text(part.0).font(.subheadline)
                        Spacer()
                        Text(MoneyText.whole(Money(minorUnits: part.1 * 100))).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    .opacity(split ? 1 : 0).offset(y: split ? 0 : 6)
                    .animation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion)
                        .delay(reduceMotion ? 0 : 0.5 + Double(index) * FolkiMotion.cascadeStep), value: split)
                }
            }
        }
        .padding(FolkiSpacing.page)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Зарплата делится на аренду, связь, подписки и деньги на жизнь")
        .onAppear {
            guard !reduceMotion else { split = true; return }
            withAnimation(FolkiMotion.hero.delay(0.4)) { split = true }
        }
    }
}

// MARK: - Editors shared by the flow and the overview

enum PlanText {
    static func income(_ settings: PlanSettings) -> String {
        let time = String(format: "%02d:%02d", settings.hour, settings.minute)
        switch settings.income {
        case .off: return String(localized: "Напоминания о деньгах выключены")
        case .monthly(let days):
            let list = days.sorted().map(String.init).joined(separator: String(localized: " и "))
            return String(localized: "Напомню внести деньги \(list) числа в \(time)")
        case .weekly(let weekday):
            var calendar = Calendar.current; calendar.locale = .current
            let name = calendar.weekdaySymbols[(weekday - 1) % 7]
            return String(localized: "Напомню внести деньги: \(name), \(time)")
        }
    }
    /// Without the "напомню" lead, for the overview row titled "Внести деньги".
    static func incomeShort(_ settings: PlanSettings) -> String {
        let time = String(format: "%02d:%02d", settings.hour, settings.minute)
        switch settings.income {
        case .off: return String(localized: "Не напоминаю")
        case .monthly(let days):
            let list = days.sorted().map(String.init).joined(separator: String(localized: " и "))
            return String(localized: "\(list) числа в \(time)")
        case .weekly(let weekday):
            var calendar = Calendar.current; calendar.locale = .current
            return String(localized: "\(calendar.weekdaySymbols[(weekday - 1) % 7]), \(time)")
        }
    }
    static func payments(_ settings: PlanSettings) -> String {
        guard settings.paymentReminders else { return String(localized: "Напоминания о платежах выключены") }
        switch (settings.daysBefore, settings.onDueDay) {
        case (0, _): return String(localized: "В день оплаты")
        case (let days, true): return String(localized: "За \(days) дн. и в день оплаты")
        case (let days, false): return String(localized: "За \(days) дн. до оплаты")
        }
    }
}

private struct PlanChip: View {
    let title: String
    let selected: Bool
    var wide = false
    let action: () -> Void
    var body: some View {
        Button { FolkiFeedback.selection(); action() } label: {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, FolkiSpacing.card).frame(maxWidth: wide ? .infinity : nil, minHeight: 44)
                .foregroundStyle(selected ? Color.white : Color.folkiInk)
                .glassEffect(.regular.tint(selected ? Color.folkiAccent : .clear).interactive(), in: Capsule())
        }.buttonStyle(FolkiPressStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PlanIncomeEditor: View {
    @Binding var settings: PlanSettings
    enum Mode: Hashable { case monthly, twice, weekly, off }
    @State private var selectedMode: Mode?
    private var mode: Mode { selectedMode ?? storedMode }
    private var storedMode: Mode {
        switch settings.income {
        case .off: .off
        case .weekly: .weekly
        case .monthly(let days): days.count > 1 ? .twice : .monthly
        }
    }
    private var days: [Int] { if case .monthly(let days) = settings.income { days } else { [] } }
    private var time: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: .now) ?? .now },
                set: { value in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
                    settings.hour = parts.hour ?? 10; settings.minute = parts.minute ?? 0
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.page) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: FolkiSpacing.xs), GridItem(.flexible())], spacing: FolkiSpacing.xs) {
                PlanChip(title: String(localized: "Раз в месяц"), selected: mode == .monthly, wide: true) { setMode(.monthly) }
                PlanChip(title: String(localized: "Два раза в месяц"), selected: mode == .twice, wide: true) { setMode(.twice) }
                PlanChip(title: String(localized: "Каждую неделю"), selected: mode == .weekly, wide: true) { setMode(.weekly) }
                PlanChip(title: String(localized: "Не напоминать"), selected: mode == .off, wide: true) { setMode(.off) }
            }
            switch mode {
            case .monthly, .twice:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FolkiSpacing.xs), count: 7), spacing: FolkiSpacing.xs) {
                    ForEach(1...31, id: \.self) { day in dayButton(day) }
                }
            case .weekly:
                weekdays
            case .off:
                Text("Внести можно в любой момент")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if mode != .off {
                HStack(spacing: FolkiSpacing.item) {
                    Image(systemName: "bell.badge.fill").font(.body.weight(.semibold)).foregroundStyle(Color.folkiAccent)
                        .symbolRenderingMode(.hierarchical)
                    DatePicker("Напомнить", selection: time, displayedComponents: .hourAndMinute)
                }
                    .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 52)
                    .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
            }
        }
        .animation(FolkiMotion.quick, value: settings)
    }

    private func dayButton(_ day: Int) -> some View {
        let selected = days.contains(day)
        return Button {
            FolkiFeedback.selection()
            selectedMode = mode
            var next = days.filter { $0 != day }
            if !selected { next.append(day) }
            if mode == .monthly { next = selected ? [] : [day] }
            // Keep the two-day mode while either date is being replaced.
            if mode == .twice && next.count > 2 { next.remove(at: next.count - 2) }
            settings.income = .monthly(next.sorted())
        } label: {
            Text("\(day)").font(.body.weight(selected ? .bold : .regular)).monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(selected ? Color.white : Color.folkiInk)
                .background(selected ? Color.folkiAccent : Color.folkiSoft, in: Circle())
        }.buttonStyle(FolkiPressStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var weekdays: some View {
        var calendar = Calendar.current; calendar.locale = .current
        let symbols = calendar.shortWeekdaySymbols
        // Monday first.
        let order = [2, 3, 4, 5, 6, 7, 1]
        let current: Int = { if case .weekly(let weekday) = settings.income { weekday } else { 2 } }()
        return HStack(spacing: FolkiSpacing.xs) {
            ForEach(order, id: \.self) { weekday in
                let selected = current == weekday
                Button { FolkiFeedback.selection(); settings.income = .weekly(weekday) } label: {
                    Text(symbols[weekday - 1]).font(.subheadline.weight(selected ? .bold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selected ? Color.white : Color.folkiInk)
                        .background(selected ? Color.folkiAccent : Color.folkiSoft, in: Capsule())
                }.buttonStyle(FolkiPressStyle())
            }
        }
    }

    private func setMode(_ mode: Mode) {
        selectedMode = mode
        switch mode {
        case .off: settings.income = .off
        case .weekly: settings.income = .weekly(2)
        case .monthly: settings.income = .monthly(Array(days.prefix(1)).isEmpty ? [10] : Array(days.prefix(1)))
        case .twice: settings.income = .monthly(days.count >= 2 ? Array(days.prefix(2)) : [10, 25])
        }
    }
}

struct PlanPaymentsEditor: View {
    @Binding var settings: PlanSettings
    var body: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.page) {
            Toggle("Напоминать о платежах", isOn: $settings.paymentReminders)
                .font(.body.weight(.medium))
                .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 52)
                .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
            if settings.paymentReminders {
                Text("Заранее").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: FolkiSpacing.xs) {
                    PlanChip(title: String(localized: "За день"), selected: settings.daysBefore == 1) { settings.daysBefore = 1 }
                    PlanChip(title: String(localized: "За 2 дня"), selected: settings.daysBefore == 2) { settings.daysBefore = 2 }
                    PlanChip(title: String(localized: "За неделю"), selected: settings.daysBefore == 7) { settings.daysBefore = 7 }
                }
                Toggle("И в день оплаты", isOn: $settings.onDueDay)
                    .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 52)
                    .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
                // What a reminder will look like.
                HStack(alignment: .top, spacing: FolkiSpacing.item) {
                    Image(systemName: "app.badge.fill").font(.title2).foregroundStyle(Color.folkiAccent)
                    VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
                        Text("Аренда — 25 000 ₽ через \(max(1, settings.daysBefore)) дн.").font(.subheadline.weight(.semibold))
                        Text("Не хватает 4 000 ₽ — переложи из денег на жизнь").font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(FolkiSpacing.card).frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
                .accessibilityLabel("Пример напоминания")
            }
        }
        .tint(Color.folkiAccent)
        .animation(FolkiMotion.quick, value: settings)
    }
}

/// The family share of each personal top-up: this member's own percent or the family default.
struct PlanFamilyEditor: View {
    let family: BudgetSession
    @Binding var percent: Double
    @Binding var forEveryone: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.page) {
            VStack(alignment: .leading, spacing: FolkiSpacing.item) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(percent))%").font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText()).animation(FolkiMotion.quick, value: percent)
                    Spacer()
                    Image(systemName: "heart.fill").font(.title).foregroundStyle(RingPalette.family.start)
                }
                Slider(value: $percent, in: 0...50, step: 5).tint(RingPalette.family.start)
                    .accessibilityLabel("Доля для семьи").accessibilityValue("\(Int(percent))%")
                Text("С 50 000 ₽ в семью уйдёт \(MoneyText.whole(Money(minorUnits: Int64(percent) * 50_000)))")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(FolkiSpacing.page)
            .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
            Toggle(isOn: $forEveryone) {
                VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
                    Text("Для всей семьи")
                }
            }
            .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 60)
            .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
            .tint(RingPalette.family.start)
        }
    }
}

// MARK: - Overview

private struct PlanOverview: View {
    let personal: BudgetSession
    let family: BudgetSession
    @Binding var pendingEnvelope: UUID?
    /// The wizard is open; the tab keeps this page under it.
    @Binding var wizardOpen: Bool
    let saved: (Bool) -> Void
    let closed: () -> Void
    @State private var path: [RecurringEnvelope] = []
    @State private var scope: BudgetScope = .personal
    @State private var creating = false
    @State private var basics = false
    @State private var editing: Part?
    @State private var settings = PlanSettings.load()
    @State private var notificationsOff = false
    @State private var confirmingReset = false
    @State private var resetError: String?
    @Namespace private var zoom
    enum Part: String, Identifiable { case income, payments, family; var id: String { rawValue } }
    private var session: BudgetSession { scope == .family && family.household != nil ? family : personal }

    @State private var distributing = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: FolkiSpacing.section) {
                    if notificationsOff && settings.usesNotifications {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            Label("Уведомления выключены — напоминания не придут. Включить", systemImage: "bell.slash")
                                .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(FolkiSpacing.card)
                                .background(Color.folkiWarningGround, in: RoundedRectangle(cornerRadius: FolkiSpacing.controlRadius))
                                .foregroundStyle(Color.folkiWarning)
                        }.buttonStyle(.plain)
                    }
                    Button { distributing = true } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("На жизнь", value: MoneyText.whole(session.availableForDailySpending))
                                .font(.headline)
                            Text("Распределить по конвертам").font(.subheadline).foregroundStyle(Color.folkiAccent)
                        }.budgetCard()
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: FolkiSpacing.item) {
                        HStack {
                            Text("Конверты с деньгами").font(.title2.bold())
                            Spacer()
                            Menu {
                                Button("Перенастроить", systemImage: "slider.horizontal.3") { basics = true }
                                Button("Сбросить план", systemImage: "arrow.counterclockwise", role: .destructive) { confirmingReset = true }
                            } label: {
                                Image(systemName: "ellipsis").font(.headline).frame(width: 40, height: 40)
                                    .glassEffect(.regular.interactive(), in: Circle())
                            }
                            .matchedTransitionSource(id: "plan", in: zoom)
                            .accessibilityLabel("Настройки плана")
                        }
                        if family.household != nil {
                            FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: $scope,
                                options: [(String(localized: "Личные"), .personal), (String(localized: "Семейные"), .family)], minimumHeight: 36)
                        }
                        EnvelopesSection(session: session, creating: $creating)
                        Text("Пополнение конверта — не трата")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: FolkiSpacing.item) {
                        Text("Траты на жизнь").font(.title2.bold())
                        Text("Продукты, кафе и остальное — только для статистики, пополнять не нужно")
                            .font(.subheadline).foregroundStyle(.secondary)
                        NavigationLink { CategoriesView(session: session) } label: {
                            Label("Категории трат", systemImage: "tag")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(FolkiSoftButtonStyle())
                    }
                    VStack(alignment: .leading, spacing: FolkiSpacing.item) {
                        Text("Напоминания").font(.title2.bold())
                        row("bell.badge", String(localized: "Внести деньги"), PlanText.incomeShort(settings), .income)
                        row("calendar.badge.exclamationmark", String(localized: "Платежи"), PlanText.payments(settings), .payments)
                    }
                    if family.household != nil {
                        let percents = family.contributionPercents
                        VStack(alignment: .leading, spacing: FolkiSpacing.item) {
                            Text("Семья").font(.title2.bold())
                            row("heart", String(localized: "Вклад в семью"),
                                percents.mine.map { String(localized: "\($0)% — твой процент") }
                                    ?? String(localized: "\(percents.family)% — общий для семьи"), .family)
                        }
                    }
                }.folkiPagePadding(top: FolkiSpacing.xs)
            }
            .background { FolkiBackground() }
            .navigationTitle("План").toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: RecurringEnvelope.self) { envelope in
                // The envelope may belong to either budget: a widget link does not know the selected one.
                EnvelopeDetailView(session: family.envelopes.contains { $0.id == envelope.id } ? family : personal,
                                   envelopeID: envelope.id)
            }
            .onChange(of: pendingEnvelope, initial: true) { _, id in
                guard let id else { return }
                pendingEnvelope = nil
                guard let envelope = (personal.envelopes + family.envelopes).first(where: { $0.id == id }) else { return }
                path = [envelope]
            }
            .sheet(isPresented: $distributing) {
                DailyFundingView(personal: personal, family: family, initialScope: scope, distributesExisting: true)
            }
            .sheet(isPresented: $creating) { EnvelopeEditorView(session: session) }
            .onChange(of: basics) { _, open in wizardOpen = open }
            .fullScreenCover(isPresented: $basics, onDismiss: closed) {
                NavigationStack {
                    PlanWizardView(personal: personal, family: family, startsWithHello: false,
                                   finish: { saved($0); basics = false }, cancel: { basics = false })
                        .toolbar(.hidden, for: .navigationBar)
                }
                .navigationTransition(.zoom(sourceID: "plan", in: zoom))
            }
            .sheet(item: $editing, onDismiss: { settings = PlanSettings.load() }) { part in
                PlanPartEditor(part: part, personal: personal, family: family)
            }
            .task { await checkNotifications() }
            .alert("Не получилось сбросить план", isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
                Button("Готово") { resetError = nil }
            } message: { Text(resetError ?? "") }
            .confirmationDialog("Сбросить план?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Сбросить", role: .destructive, action: resetPlan)
            } message: {
                Text("Личные конверты и напоминания удалятся, деньги из них вернутся на жизнь. Семейные конверты останутся")
            }
        }
    }

    private func resetPlan() {
        do {
            for envelope in personal.envelopes { try personal.archiveEnvelope(envelope) }
        } catch {
            resetError = String(localized: "Не все конверты закрылись. Деньги из закрытых уже вернулись на жизнь. Попробуй ещё раз.")
            return
        }
        UserDefaults.standard.removeObject(forKey: "FolkiPlanSettings")
        UserDefaults.standard.removeObject(forKey: "FolkiPlanIncome")
        Task { await PlanReminders.reschedule(PlanSettings(), sessions: [personal, family]) }
        FolkiFeedback.saved()
    }

    private func row(_ symbol: String, _ title: String, _ value: String, _ part: Part) -> some View {
        Button { editing = part } label: {
            HStack(spacing: FolkiSpacing.item) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Color.folkiAccent)
                    .frame(width: 40, height: 40).background(Color.folkiAccent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Color.folkiInk)
                    Text(value).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(FolkiSpacing.card)
            .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
        }.buttonStyle(FolkiPressStyle(scale: 0.98))
    }

    private func checkNotifications() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsOff = status == .denied
    }
}

/// One part of the plan in its own sheet.
private struct PlanPartEditor: View {
    let part: PlanOverview.Part
    let personal: BudgetSession
    let family: BudgetSession
    @Environment(\.dismiss) private var dismiss
    @State private var settings = PlanSettings.load()
    @State private var percent = 30.0
    @State private var forEveryone = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FolkiSpacing.page) {
                    switch part {
                    case .income: PlanIncomeEditor(settings: $settings)
                    case .payments: PlanPaymentsEditor(settings: $settings)
                    case .family: PlanFamilyEditor(family: family, percent: $percent, forEveryone: $forEveryone)
                    }
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                }.padding(FolkiSpacing.page)
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { FolkiCloseButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Готово", action: save) }
            }
        }
        .onAppear {
            let current = family.contributionPercents
            percent = Double(current.mine ?? current.family)
        }
    }

    private var title: String {
        switch part {
        case .income: String(localized: "Внести деньги")
        case .payments: String(localized: "Платежи")
        case .family: String(localized: "Вклад в семью")
        }
    }

    private func save() {
        if part == .family {
            do { try family.setContributionPercent(Int(percent), forEveryone: forEveryone) }
            catch { errorMessage = String(localized: "Не получилось сохранить процент. Попробуй ещё раз."); return }
            FolkiFeedback.saved(); dismiss(); return
        }
        settings.save()
        Task {
            if settings.usesNotifications { _ = await PlanReminders.requestPermission() }
            await PlanReminders.reschedule(settings, sessions: [personal, family])
            FolkiFeedback.saved()
            dismiss()
        }
    }
}
