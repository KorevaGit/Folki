import SwiftUI
import UIKit
import UserNotifications
import FolkiDuoCore

/// "План": regular payments, reminders and the family share. Until it is set up the tab is a short
/// onboarding-style walk-through; afterwards each part is edited on its own.
struct PlanTab: View {
    let personal: BudgetSession
    let family: BudgetSession
    @AppStorage("FolkiPlanReady") private var ready = false

    var body: some View {
        if ready {
            PlanOverview(personal: personal, family: family)
        } else {
            PlanSetupFlow(personal: personal, family: family) {
                withAnimation(FolkiMotion.standard) { ready = true }
            }
        }
    }
}

// MARK: - Setup flow

private struct PlanSetupFlow: View {
    let personal: BudgetSession
    let family: BudgetSession
    let finish: () -> Void

    enum Step: Int, CaseIterable { case hello, about, income, envelopes, payments, family, done }
    @State private var step: Step = .hello
    @State private var forward = true
    @State private var settings = PlanSettings.load()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hasFamily: Bool { family.household != nil }
    /// The numbered steps, for the progress bar.
    private var setupSteps: [Step] { hasFamily ? [.income, .envelopes, .payments, .family] : [.income, .envelopes, .payments] }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 56).padding(.horizontal, FolkiSpacing.page)
            ZStack {
                page.id(step).transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }
        .padding(.bottom, FolkiSpacing.item)
        .background { FolkiBackground() }
        .onAppear {
            // Never set up: suggest the payday the budget already knows.
            guard UserDefaults.standard.data(forKey: "FolkiPlanSettings") == nil, case .off = settings.income else { return }
            let day = personal.household.map { personal.calendar.component(.day, from: $0.period.endExclusive) } ?? 10
            settings.income = .monthly([min(28, day)])
        }
    }

    private var header: some View {
        HStack(spacing: FolkiSpacing.item) {
            if step != .hello && step != .done {
                Button { go(previous, forward: false) } label: {
                    Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44)
                }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Назад")
            }
            if let index = setupSteps.firstIndex(of: step) {
                HStack(spacing: 6) {
                    ForEach(setupSteps.indices, id: \.self) { item in
                        Capsule().fill(item <= index ? Color.folkiAccent : Color.folkiSoft).frame(height: 4)
                    }
                }.animation(FolkiMotion.quick, value: step).accessibilityLabel("Шаг \(index + 1) из \(setupSteps.count)")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .hello:
            OnboardingPage(centered: true) {
                VStack(spacing: FolkiSpacing.large) {
                    PlanHeroArt().frame(width: 240, height: 200)
                    VStack(spacing: FolkiSpacing.item) {
                        Text("Финансовый план").font(.largeTitle.bold()).rise(6)
                        Text("Сейчас я считаю только повседневные траты. Давай учтём и регулярные: аренду, связь, подписки")
                            .font(.body).foregroundStyle(.secondary).rise(7)
                    }.multilineTextAlignment(.center)
                }.padding(.bottom, FolkiSpacing.huge)
            } actions: {
                Button("Составить план") { go(.about) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).rise(8)
            }
        case .about:
            OnboardingPage {
                VStack(alignment: .leading, spacing: FolkiSpacing.large) {
                    Text("Что будет в плане").font(.largeTitle.bold())
                    feature("bell.badge", "Напомню внести деньги", "В дни зарплаты или раз в неделю").rise(1)
                    feature("tray.full", "Отложу на платежи", "Каждый платёж — свой конверт. Дневной бюджет их не трогает").rise(2)
                    feature("calendar.badge.exclamationmark", "Предупрежу о списаниях", "Заранее, если в конверте не хватает").rise(3)
                    if hasFamily {
                        feature("heart", "Поделюсь с семьёй", "Часть каждого пополнения — в общий бюджет").rise(4)
                    }
                    Text("Займёт пару минут. Всё можно поменять потом").font(.subheadline).foregroundStyle(.secondary).rise(5)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, FolkiSpacing.page)
            } actions: {
                Button("Начать") { go(.income) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            }
        case .income:
            OnboardingPage {
                VStack(alignment: .leading, spacing: FolkiSpacing.page) {
                    stepTitle("Когда приходят деньги?", "В эти дни напомню внести их и разложить по конвертам")
                    PlanIncomeEditor(settings: $settings)
                }.padding(.top, FolkiSpacing.page)
            } actions: {
                Button("Дальше") { Task { await saveReminders(); go(.envelopes) } }
                    .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            }
        case .envelopes:
            PlanEnvelopesStep(personal: personal, family: family) { go(.payments) }
        case .payments:
            OnboardingPage {
                VStack(alignment: .leading, spacing: FolkiSpacing.page) {
                    stepTitle("Напоминать о платежах?", "Скажу заранее, сколько не хватает в конверте")
                    PlanPaymentsEditor(settings: $settings)
                }.padding(.top, FolkiSpacing.page)
            } actions: {
                Button("Дальше") { Task { await saveReminders(); go(hasFamily ? .family : .done) } }
                    .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            }
        case .family:
            PlanFamilyStep(family: family) { go(.done) }
        case .done:
            OnboardingPage(centered: true) {
                VStack(spacing: FolkiSpacing.large) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 88)).foregroundStyle(Color.folkiAccent)
                        .symbolEffect(.bounce, options: .nonRepeating)
                    VStack(spacing: FolkiSpacing.item) {
                        Text("План готов").font(.largeTitle.bold()).rise(2)
                        Text(summary).font(.body).foregroundStyle(.secondary).rise(3)
                    }.multilineTextAlignment(.center)
                }.padding(.bottom, FolkiSpacing.huge)
            } actions: {
                Button("Готово") { FolkiFeedback.saved(); finish() }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).rise(4)
            }
        }
    }

    private var summary: String {
        let count = personal.envelopes.count + family.envelopes.count
        let envelopes = count == 0 ? String(localized: "Конвертов пока нет — добавишь, когда понадобятся")
            : String(localized: "Конвертов: \(count)")
        return [envelopes, PlanText.income(settings), PlanText.payments(settings)].joined(separator: "\n")
    }

    private var previous: Step {
        switch step {
        case .family: .payments
        case .done: hasFamily ? .family : .payments
        default: Step(rawValue: max(0, step.rawValue - 1)) ?? .hello
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: FolkiSpacing.card) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.folkiAccent)
                .frame(width: 48, height: 48).background(Color.folkiAccent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func go(_ next: Step, forward: Bool = true) {
        self.forward = forward
        withAnimation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion)) { step = next }
    }

    private func saveReminders() async {
        settings.save()
        if settings.usesNotifications { _ = await PlanReminders.requestPermission() }
        await PlanReminders.reschedule(settings, sessions: [personal, family])
    }
}

private func stepTitle(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: FolkiSpacing.xs) {
        Text(title).font(.largeTitle.bold())
        Text(detail).font(.body).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
}

/// Three envelopes fan out of a stack: rent, internet, a bell.
private struct PlanHeroArt: View {
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let cards: [(String, Color, Double)] = [
        ("house.fill", Color(red: 0.62, green: 0.42, blue: 0.24), -14), ("wifi", Color(red: 0.30, green: 0.56, blue: 0.86), 0),
        ("bell.fill", Color.folkiWarning, 14)
    ]
    var body: some View {
        ZStack {
            ForEach(cards.indices, id: \.self) { index in
                let card = cards[index]
                RoundedRectangle(cornerRadius: 22).fill(card.1.gradient)
                    .frame(width: 120, height: 150)
                    .overlay { Image(systemName: card.0).font(.system(size: 40, weight: .semibold)).foregroundStyle(.white) }
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                    .rotationEffect(.degrees(open ? card.2 : 0), anchor: .bottom)
                    .offset(x: open ? CGFloat(index - 1) * 62 : 0, y: open ? (index == 1 ? -10 : 6) : 0)
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { open = true; return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.68).delay(0.25)) { open = true }
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
    private var mode: Mode {
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
                Text(mode == .twice ? "Выбери два дня, например зарплату и аванс" : "Выбери день зарплаты")
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(1...28, id: \.self) { day in dayButton(day) }
                }
            case .weekly:
                weekdays
            case .off:
                Text("Ничего не напомню. Деньги можно внести в любой момент кнопкой «Внести»")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if mode != .off {
                DatePicker("Время напоминания", selection: time, displayedComponents: .hourAndMinute)
                    .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 52)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
            }
        }
        .animation(FolkiMotion.quick, value: settings)
    }

    private func dayButton(_ day: Int) -> some View {
        let selected = days.contains(day)
        return Button {
            FolkiFeedback.selection()
            var next = days.filter { $0 != day }
            if !selected { next.append(day) }
            if mode == .monthly { next = selected ? [] : [day] }
            if mode == .twice && next.count > 2 { next.removeFirst() }
            settings.income = .monthly(next.sorted())
        } label: {
            Text("\(day)").font(.body.weight(selected ? .bold : .regular)).monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 40)
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
        return HStack(spacing: 6) {
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
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
            if settings.paymentReminders {
                Text("Заранее").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: FolkiSpacing.xs) {
                    PlanChip(title: String(localized: "За день"), selected: settings.daysBefore == 1) { settings.daysBefore = 1 }
                    PlanChip(title: String(localized: "За 2 дня"), selected: settings.daysBefore == 2) { settings.daysBefore = 2 }
                    PlanChip(title: String(localized: "За неделю"), selected: settings.daysBefore == 7) { settings.daysBefore = 7 }
                }
                Toggle("И в день оплаты", isOn: $settings.onDueDay)
                    .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 52)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
                // What a reminder will look like.
                HStack(alignment: .top, spacing: FolkiSpacing.item) {
                    Image(systemName: "app.badge.fill").font(.title2).foregroundStyle(Color.folkiAccent)
                    VStack(alignment: .leading, spacing: 2) {
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
private struct PlanFamilyEditor: View {
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
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
            Toggle(isOn: $forEveryone) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Для всей семьи")
                    Text("Иначе процент только твой").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 60)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
            .tint(RingPalette.family.start)
            Text("При пополнении личного бюджета предложу перевести эту долю. Если семейный платёж близко, предложу больше")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct PlanFamilyStep: View {
    let family: BudgetSession
    let next: () -> Void
    @State private var percent = 30.0
    @State private var forEveryone = false
    @State private var errorMessage: String?
    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: FolkiSpacing.page) {
                stepTitle("Сколько в семью?", "Доля от каждого пополнения личного бюджета")
                PlanFamilyEditor(family: family, percent: $percent, forEveryone: $forEveryone)
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }.padding(.top, FolkiSpacing.page)
        } actions: {
            Button("Дальше") {
                do { try family.setContributionPercent(Int(percent), forEveryone: forEveryone); next() }
                catch { errorMessage = String(localized: "Не получилось сохранить процент. Попробуй ещё раз.") }
            }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        }
        .onAppear {
            let current = family.contributionPercents
            percent = Double(current.mine ?? current.family)
        }
    }
}

private struct PlanEnvelopesStep: View {
    let personal: BudgetSession
    let family: BudgetSession
    let next: () -> Void
    @State private var scope: BudgetScope = .personal
    @State private var creating = false
    private var session: BudgetSession { scope == .family && family.household != nil ? family : personal }
    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: FolkiSpacing.page) {
                stepTitle("Регулярные платежи", "Каждый — свой конверт. Буду откладывать на него из поступлений")
                if family.household != nil {
                    FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: $scope,
                        options: [(String(localized: "Личные"), .personal), (String(localized: "Семейные"), .family)], minimumHeight: 36)
                }
                if session.envelopes.isEmpty {
                    Button { creating = true } label: {
                        Label("Добавить конверт", systemImage: "plus").font(.headline).frame(maxWidth: .infinity, minHeight: 64)
                    }.buttonStyle(FolkiSoftButtonStyle())
                } else {
                    VStack(spacing: FolkiSpacing.xs) {
                        ForEach(session.envelopes) { envelope in
                            HStack {
                                Text(envelope.name).font(.body.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text("\(MoneyText.whole(envelope.size)) · \(envelope.dueDay)-го").font(.subheadline)
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 52)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        Button { creating = true } label: {
                            Label("Ещё конверт", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(FolkiSoftButtonStyle())
                    }.animation(FolkiMotion.standard, value: session.envelopes)
                }
            }.padding(.top, FolkiSpacing.page)
        } actions: {
            Button(personal.envelopes.isEmpty && family.envelopes.isEmpty ? String(localized: "Пока без конвертов") : String(localized: "Дальше"),
                   action: next)
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        }
        .sheet(isPresented: $creating) { EnvelopeEditorView(session: session) }
    }
}

// MARK: - Overview

private struct PlanOverview: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var scope: BudgetScope = .personal
    @State private var creating = false
    @State private var editing: Part?
    @State private var settings = PlanSettings.load()
    @State private var notificationsOff = false
    enum Part: String, Identifiable { case income, payments, family; var id: String { rawValue } }
    private var session: BudgetSession { scope == .family && family.household != nil ? family : personal }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FolkiSpacing.section) {
                    if notificationsOff && settings.usesNotifications {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            Label("Уведомления выключены — напоминания не придут. Включить", systemImage: "bell.slash")
                                .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(FolkiSpacing.card)
                                .background(Color.folkiWarningGround, in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(Color.folkiWarning)
                        }.buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: FolkiSpacing.item) {
                        Text("Конверты").font(.title2.bold())
                        if family.household != nil {
                            FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: $scope,
                                options: [(String(localized: "Личные"), .personal), (String(localized: "Семейные"), .family)], minimumHeight: 36)
                        }
                        EnvelopesSection(session: session, creating: $creating)
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
                EnvelopeDetailView(session: session, envelopeID: envelope.id)
            }
            .sheet(isPresented: $creating) { EnvelopeEditorView(session: session) }
            .sheet(item: $editing, onDismiss: { settings = PlanSettings.load() }) { part in
                PlanPartEditor(part: part, personal: personal, family: family)
            }
            .task { await checkNotifications() }
        }
    }

    private func row(_ symbol: String, _ title: String, _ value: String, _ part: Part) -> some View {
        Button { editing = part } label: {
            HStack(spacing: FolkiSpacing.item) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Color.folkiAccent)
                    .frame(width: 40, height: 40).background(Color.folkiAccent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Color.folkiInk)
                    Text(value).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(FolkiSpacing.card)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
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
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
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
