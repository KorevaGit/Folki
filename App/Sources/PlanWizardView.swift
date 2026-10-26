import SwiftUI
import FolkiDuoCore

/// The plan walk-through. Text stays minimal: every input changes the daily estimate and the income bar
/// at the bottom, so the consequence explains the question.
struct PlanWizardView: View {
    let personal: BudgetSession
    let family: BudgetSession
    /// Reconfiguring an existing plan skips the welcome.
    var startsWithHello = true
    /// Saved. `offerDistribution`: there is money to put into the new envelopes, offered once the wizard has closed.
    let finish: (_ offerDistribution: Bool) -> Void
    /// Leaving without saving; nil when the wizard is the tab itself, which then starts over.
    var cancel: (() -> Void)? = nil
    @State private var confirmingExit = false

    enum Step: Int, CaseIterable { case hello, income, payday, payments, savings, family, done }
    @State private var step: Step = .hello
    @State private var forward = true
    @State private var incomeText = ""
    @State private var settings = PlanSettings.load()
    private var paydays: [Int] { if case .monthly(let days) = settings.income { days } else { [] } }
    @State private var items: [Item] = []
    @State private var percent = 30.0
    @State private var forEveryone = false
    @State private var usesBalance = false
    @State private var shake = 0
    @State private var errorMessage: String?
    @State private var loaded = false
    /// The envelope whose amount the keypad is typing.
    /// The envelope open on top of the list: a new one until added, or a copy of an existing one.
    @State private var draft: Item?
    @State private var draftIsNew = false
    /// The large title has scrolled away: the header shows it small.
    @State private var scrolled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Item: Identifiable, Equatable {
        var id = UUID()
        var existing = false
        var name: String
        var symbol: String
        var color: CategoryColor
        var categoryID: UUID
        var mandatory: Bool
        var amount = ""
        var day: Int
        /// Savings: months to reach the goal; the envelope gets the goal spread over them.
        var months = 12
        /// Savings by a chosen monthly amount: Folki then says how long it takes.
        var byMonthly = false
        var monthly = ""
        /// A user-made envelope: its name is typed.
        var custom = false
        /// What the keypad typed: a payment, or the whole goal for savings.
        @MainActor var typed: Int64 { (try? MoneyText.parse(amount))?.minorUnits ?? 0 }
        /// What one salary cycle sets aside.
        @MainActor var monthlyMinor: Int64 { (try? MoneyText.parse(monthly))?.minorUnits ?? 0 }
        @MainActor var minor: Int64 {
            if mandatory { return typed }
            if byMonthly { return monthlyMinor }
            return (typed + Int64(months) - 1) / Int64(max(1, months))
        }
        /// Months until the goal is reached.
        @MainActor var reachMonths: Int {
            guard byMonthly else { return months }
            return monthlyMinor > 0 ? max(1, Int((typed + monthlyMinor - 1) / monthlyMinor)) : 0
        }
    }

    struct Template: Identifiable {
        let name: String, symbol: String, color: CategoryColor, categoryID: UUID
        var id: String { name }
        init(_ category: SpendingCategory, name: String? = nil) {
            self.name = name ?? category.name; symbol = category.symbol; color = category.color; categoryID = category.id
        }
        init(name: String, symbol: String, color: CategoryColor, category: BuiltInCategory) {
            self.name = name; self.symbol = symbol; self.color = color; categoryID = category.id
        }
    }
    /// Regular payments: every category that is paid on a date, plus the user's own categories.
    private var paymentTemplates: [Template] {
        let builtIn: [BuiltInCategory] = [.housing, .connectivity, .debt, .children, .health, .transport, .beauty]
        return builtIn.map { Template($0.category) }
            + personal.catalog.selectable.filter { !$0.isBuiltIn }.map { Template($0) }
    }
    /// Things to save up for: a reward, not a duty.
    private static let goals: [Template] = [
        Template(name: String(localized: "Отпуск"), symbol: "airplane", color: .sky, category: .travel),
        Template(name: String(localized: "Подушка"), symbol: "shield.fill", color: .cyan, category: .other),
        Template(name: String(localized: "Техника"), symbol: "laptopcomputer", color: .indigo, category: .other),
        Template(name: String(localized: "Машина"), symbol: "car.fill", color: .slate, category: .transport),
        Template(name: String(localized: "Ремонт"), symbol: "paintbrush.fill", color: .brown, category: .housing),
        Template(name: String(localized: "Обучение"), symbol: "graduationcap.fill", color: .purple, category: .other),
        Template(name: String(localized: "Подарки"), symbol: "gift.fill", color: .plum, category: .gifts),
        Template(name: String(localized: "Мечта"), symbol: "sparkles", color: .pink, category: .other)
    ]
    /// Money left after the regular payments: savings are a share of it.
    private var free: Int64 { max(0, income - planned.filter(\.mandatory).reduce(0) { $0 + $1.minor }) }

    private var hasFamily: Bool { family.household != nil }
    private var steps: [Step] {
        Step.allCases.filter { ($0 != .family || hasFamily) && ($0 != .hello || startsWithHello) }
    }
    private var progressSteps: [Step] { steps.filter { $0 != .hello && $0 != .done } }
    private var calendar: Calendar { personal.calendar }
    private var income: Int64 { (try? MoneyText.parse(incomeText))?.minorUnits ?? 0 }
    /// The list as it would be with the open envelope applied.
    private var planned: [Item] {
        guard let draft else { return items }
        if let index = items.firstIndex(where: { $0.id == draft.id }) { var next = items; next[index] = draft; return next }
        return items + [draft]
    }
    private var reserved: Int64 { planned.reduce(0) { $0 + $1.minor } }
    /// For the cushion: three months of what is spent — the income less what the other jars put aside —
    /// rounded up to a thousand.
    private var cushionTarget: Int64 {
        guard let draft, !draft.mandatory, draft.name == String(localized: "Подушка"), income > 0 else { return 0 }
        let saved = items.filter { !$0.mandatory && $0.id != draft.id }.reduce(0) { $0 + $1.minor }
        let target = max(0, income - saved) * 3
        return (target + 99_999) / 100_000 * 100_000
    }
    private var capacity: PlanCapacity {
        PlanCapacity(income: income, reserved: reserved, days: cycleDays,
                     availableBalance: personal.availableForDailySpending.minorUnits, usesBalance: usesBalance)
    }
    private var living: Int64 { capacity.living }
    /// One salary cycle: from a payday to the same day next month.
    private var cycleDays: Int {
        let today = calendar.startOfDay(for: personal.referenceDate)
        guard let first = paydays.first,
              let start = try? EnvelopeSchedule.firstDue(day: first, onOrAfter: today, calendar: calendar),
              let next = calendar.date(byAdding: .month, value: 1, to: start) else {
            return calendar.range(of: .day, in: .month, for: today)?.count ?? 30
        }
        return max(1, calendar.dateComponents([.day], from: start, to: next).day ?? 30)
    }
    private var daily: Int64 { max(0, living) / Int64(cycleDays) }
    /// At least one day's money stays for living, like the starter allocation.
    private var over: Bool { income > 0 && capacity.shortfall > 0 }

    var body: some View {
        ZStack {
            page.id(step).transition(.asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Content scrolls under the floating controls instead of being cut at their edge.
        .overlay(alignment: .top) { header.frame(height: 56).padding(.horizontal, FolkiSpacing.page) }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .toolbar(.hidden, for: .tabBar)
        .background { FolkiBackground() }
        .onAppear(perform: load)
        .sensoryFeedback(.warning, trigger: over) { _, new in new }
        .sheet(isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } })) {
            if draft != nil {
                DraftSheet(item: Binding(get: { draft ?? Item(name: "", symbol: "tag.fill", color: .gray, categoryID: BuiltInCategory.other.id, mandatory: true, day: 1) }, set: { if draft != nil { draft = $0 } }), isNew: draftIsNew, free: free, cushionTarget: cushionTarget,
                           daily: daily, over: over, recoveryVisible: over || capacity.balanceUsed > 0,
                           recovery: { recovery }, commit: commitDraft, cancel: closeDraft,
                           remove: { if let id = draft?.id { remove(id) } })
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        GlassEffectContainer(spacing: FolkiSpacing.item) {
        HStack(spacing: FolkiSpacing.item) {
            if step != steps.first {
                Button { go(back: true) } label: {
                    Image(systemName: "chevron.left").font(FolkiFont.headline).frame(width: 44, height: 44)
                }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Назад")
            }
            if scrolled, let small = stepTitle {
                Text(small).font(FolkiFont.headline).lineLimit(1).frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let index = progressSteps.firstIndex(of: step) {
                HStack(spacing: FolkiSpacing.xs) {
                    ForEach(progressSteps.indices, id: \.self) { item in
                        Capsule().fill(item <= index ? Color.folkiAccent : Color.folkiTile).frame(height: 4)
                    }
                }
                .animation(FolkiMotion.quick, value: step)
                .accessibilityLabel("Шаг \(index + 1) из \(progressSteps.count)")
            }
            Spacer(minLength: 0)
            if step != .hello {
                Button { confirmingExit = true } label: {
                    Image(systemName: "xmark").font(FolkiFont.headline).frame(width: 44, height: 44)
                }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Закрыть")
            }
        }
        }
        .animation(FolkiMotion.quick, value: scrolled)
        .confirmationDialog("Выйти из настройки?", isPresented: $confirmingExit, titleVisibility: .visible) {
            Button("Выйти без сохранения", role: .destructive, action: exit)
            Button("Продолжить настройку", role: .cancel) {}
        } message: {
            Text("Выбранное сейчас не сохранится")
        }
    }

    /// The estimate and the income bar: the one place that explains every step.
    private var footer: some View {
        GlassEffectContainer(spacing: FolkiSpacing.card) {
        VStack(spacing: FolkiSpacing.card) {
            if income > 0 && step != .done && step != .hello {
                HStack(spacing: 12) {
                    IncomeBar(income: income, items: planned, over: over).frame(height: 14)
                        .modifier(Shake(phase: CGFloat(shake)))
                    HStack(alignment: .firstTextBaseline, spacing: FolkiSpacing.xxs) {
                        Text("≈ \(MoneyText.whole(Money(minorUnits: daily)))")
                            .font(FolkiFont.moneyCard).monospacedDigit()
                            .foregroundStyle(over ? Color.folkiOver : Color.folkiInk)
                            .contentTransition(.numericText(value: Double(daily)))
                        Text("/ день").font(FolkiFont.label).foregroundStyle(Color.folkiSecondary)
                    }.fixedSize()
                }
                .padding(.horizontal, 16).frame(height: 48)
                .glassEffect(.regular, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Примерно \(MoneyText.whole(Money(minorUnits: daily))) в день")
            }
            if (over || capacity.balanceUsed > 0) && [.payments, .savings, .done].contains(step) {
                recovery
            }
            if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            if step == .income {
                AmountKeypad(text: $incomeText)
            }
            Button(primaryTitle, action: primary)
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                .disabled(!canContinue)
        }
        }
        .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.item)
        .animation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion), value: income > 0)
        .animation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion), value: items)
        .animation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion), value: settings)
        .animation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion), value: draft)
    }

    private var primaryTitle: String {
        return switch step {
        case .hello: String(localized: "Составить план")
        case .income, .payday, .family: String(localized: "Дальше")
        case .payments: items.contains { $0.mandatory && $0.minor > 0 } ? String(localized: "Дальше") : String(localized: "Нет обязательных")
        case .savings: items.contains { !$0.mandatory && $0.minor > 0 } ? String(localized: "Дальше") : String(localized: "Пока не коплю")
        case .done: String(localized: "Сохранить план")
        }
    }
    private var canContinue: Bool {
        return switch step {
        case .income: income > 0
        case .payday: settings.income != .monthly([])
        case .payments, .savings, .done: !over
        default: true
        }
    }

    /// The same actions are reachable while typing a draft and after returning to the plan.
    private var recovery: PlanRecoveryView {
        PlanRecoveryView(capacity: capacity, available: personal.availableForDailySpending.minorUnits,
                         usesBalance: $usesBalance) { recommended in
            withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) {
                incomeText = MoneyText.input(Money(minorUnits: recommended))
            }
            FolkiFeedback.selection()
        }
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: FolkiSpacing.section) {
                switch step {
                case .hello: helloPage
                case .income: incomePage
                case .payday: paydayPage
                case .payments: itemsPage(String(localized: "Что платишь каждый месяц?"), templates: paymentTemplates, mandatory: true)
                case .savings: itemsPage(String(localized: "На что накопим?"), templates: Self.goals, mandatory: false)
                case .family:
                    title(String(localized: "Сколько в семью?"))
                    PlanFamilyEditor(family: family, percent: $percent, forEveryone: $forEveryone)
                case .done: donePage
                }
            }
            .frame(maxWidth: FolkiSpacing.maxWidth, alignment: .leading)
            .padding(.horizontal, FolkiSpacing.page).padding(.top, FolkiSpacing.xs).padding(.bottom, FolkiSpacing.page)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        // Room for the floating header; content fades out beneath it instead of being cut.
        .contentMargins(.top, 60, for: .scrollContent)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 56)
                Rectangle()
            }
        }
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 48 } action: { _, value in
            scrolled = value
        }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(FolkiFont.title).frame(maxWidth: .infinity, alignment: .leading)
            .opacity(scrolled ? 0 : 1).animation(FolkiMotion.quick, value: scrolled)
            .rise(0)
    }

    private var stepTitle: String? {
        switch step {
        case .hello: nil
        case .income: String(localized: "Доход")
        case .payday: String(localized: "Когда приходят деньги")
        case .payments: String(localized: "Платежи")
        case .savings: String(localized: "Накопления")
        case .family: String(localized: "Семья")
        case .done: String(localized: "Проверь план")
        }
    }

    private var helloPage: some View {
        VStack(spacing: FolkiSpacing.large) {
            PlanHeroArt().frame(maxWidth: 340).rise(0)
            VStack(spacing: FolkiSpacing.item) {
                Text("Финансовый план").font(FolkiFont.title).rise(1)
                Text("Учту аренду, связь и подписки — и они не съедят деньги на жизнь")
                    .font(FolkiFont.body).foregroundStyle(Color.folkiSecondary).rise(2)
            }.multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, FolkiSpacing.huge)
    }

    private var incomePage: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.large) {
            title(String(localized: "Сколько приходит за месяц?"))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TypedAmount(text: incomeText)
                    .font(FolkiFont.money(FolkiFont.heroSize))
                    .foregroundStyle(incomeText.isEmpty ? Color.secondary : Color.folkiInk)
                    .frame(maxWidth: .infinity)
                Text("₽").font(FolkiFont.moneyLarge).foregroundStyle(Color.folkiSecondary)
            }
            .padding(20)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
            .rise(1)
            HStack(spacing: FolkiSpacing.item) {
                ForEach([40_000, 80_000, 150_000], id: \.self) { value in
                    Button(MoneyText.whole(Money(minorUnits: Int64(value) * 100))) {
                        incomeText = String(value); FolkiFeedback.selection()
                    }
                    .font(FolkiFont.label).foregroundStyle(Color.folkiInk)
                    .padding(.horizontal, FolkiSpacing.card).frame(height: 40)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }.rise(2)
        }
    }

    private var paydayPage: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.section) {
            title(String(localized: "Когда приходят деньги?"))
            PlanIncomeEditor(settings: $settings).rise(1)
        }
    }

    private func itemsPage(_ heading: String, templates: [Template], mandatory: Bool) -> some View {
        let available = templates.filter { template in !items.contains { $0.name == template.name && $0.mandatory == mandatory } }
        return VStack(alignment: .leading, spacing: FolkiSpacing.section) {
            title(heading)
            VStack(spacing: 0) {
                ForEach($items) { $item in
                    if item.mandatory == mandatory {
                        ItemRow(item: item) { open(item) }
                        Divider().padding(.leading, 56)
                    }
                }
                do {
                    ForEach(available) { template in
                        Button { add(template, mandatory: mandatory) } label: {
                            HStack(spacing: FolkiSpacing.item) {
                                CategoryIcon(symbol: template.symbol, color: template.color.color, size: 32)
                                Text(template.name).font(FolkiFont.body).foregroundStyle(Color.folkiSecondary)
                                Spacer()
                                Image(systemName: "plus.circle.fill").font(FolkiFont.icon).foregroundStyle(Color.folkiAccent)
                            }
                            .frame(minHeight: 52).contentShape(Rectangle())
                        }
                        .buttonStyle(FolkiPressStyle(scale: 0.98))
                        Divider().padding(.leading, 56)
                    }
                    Button { addCustom(mandatory: mandatory) } label: {
                        HStack(spacing: FolkiSpacing.item) {
                            CategoryIcon(symbol: "plus", color: .gray, size: 32)
                            Text("Свой конверт").font(FolkiFont.headline).foregroundStyle(Color.folkiAccent)
                            Spacer()
                        }
                        .frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(FolkiPressStyle(scale: 0.98))
                }
            }
            .padding(.horizontal, FolkiSpacing.card).padding(.vertical, 4)
            .folkiGlassBackground()
            .rise(1)
        }
        .onChange(of: over) { _, new in if new { withAnimation(.linear(duration: 0.4)) { shake += 1 } } }
    }

    /// Everything chosen, one scroll; a tap on a section goes back to its step.
    private var donePage: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.page) {
            title(String(localized: "Проверь план"))
            VStack(spacing: 4) {
                Text("≈ \(MoneyText.whole(Money(minorUnits: daily)))")
                    .font(FolkiFont.money(FolkiFont.inputSize)).monospacedDigit()
                    .contentTransition(.numericText()).animation(FolkiMotion.quick, value: daily)
                Text(usesBalance && capacity.balanceUsed > 0 ? String(localized: "в день на этот период") : String(localized: "в день на жизнь")).font(FolkiFont.headline).foregroundStyle(Color.folkiSecondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
            .folkiGlassBackground()
            .rise(1)
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Сейчас на жизнь", value: MoneyText.whole(personal.availableForDailySpending))
                    .font(FolkiFont.headline)
            }.budgetCard()
            reviewSection(String(localized: "Доход"), .income) {
                reviewRow("banknote.fill", .folkiAccent, String(localized: "В месяц"), MoneyText.whole(Money(minorUnits: income)))
                Divider().padding(.leading, 44)
                reviewRow("bell.badge.fill", .folkiAccent, PlanText.income(settings), "")
            }.rise(2)
            reviewSection(String(localized: "Платежи"), .payments) { reviewItems(mandatory: true) }.rise(3)
            reviewSection(String(localized: "Копилки"), .savings) { reviewItems(mandatory: false) }.rise(4)
            if hasFamily {
                reviewSection(String(localized: "Семья"), .family) {
                    reviewRow("heart.fill", .pink, String(localized: "Доля пополнений"), "\(Int(percent))%")
                }.rise(5)
            }
        }
    }

    private func reviewSection<Content: View>(_ heading: String, _ target: Step, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.xs) {
            Button {
                FolkiFeedback.selection(); forward = false
                scrolled = false; withAnimation(FolkiMotion.quick) { step = target }
            } label: {
                HStack {
                    Text(heading).font(FolkiFont.section).foregroundStyle(Color.folkiInk)
                    Spacer()
                    Text("Изменить").font(FolkiFont.label).foregroundStyle(Color.folkiAccent)
                }
            }.buttonStyle(.plain)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, FolkiSpacing.card).padding(.vertical, 4)
                .folkiGlassBackground()
        }
    }

    private func reviewRow(_ symbol: String, _ color: Color, _ name: String, _ value: String, detail: String? = nil) -> some View {
        HStack(spacing: FolkiSpacing.item) {
            CategoryIcon(symbol: symbol, color: color, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(FolkiFont.headline).lineLimit(2)
                if let detail { Text(detail).folkiText(.footnote) }
            }
            Spacer()
            Text(value).font(FolkiFont.moneyRow).monospacedDigit().foregroundStyle(color)
        }
        .frame(minHeight: 52)
    }

    @ViewBuilder private func reviewItems(mandatory: Bool) -> some View {
        let chosen = items.filter { $0.mandatory == mandatory && $0.minor > 0 }
        if chosen.isEmpty {
            Text(mandatory ? "Нет обязательных платежей" : "Пока ничего не копишь")
                .folkiText(.caption).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        }
        ForEach(chosen) { item in
            reviewRow(item.symbol, item.color.color, item.name, MoneyText.whole(Money(minorUnits: item.minor)),
                      detail: mandatory ? String(localized: "\(item.day)-го") : String(localized: "цель \(MoneyText.whole(Money(minorUnits: item.typed))) · \(PlanTerm.text(item.reachMonths))"))
            if item.id != chosen.last?.id { Divider().padding(.leading, 44) }
        }
    }

    // MARK: Actions

    private func add(_ template: Template, mandatory: Bool) {
        let item = Item(name: template.name, symbol: template.symbol, color: template.color, categoryID: template.categoryID,
                        mandatory: mandatory, day: mandatory ? 25 : (paydays.first ?? 10))
        FolkiFeedback.selection()
        withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) { draft = item; draftIsNew = true }
    }

    private func addCustom(mandatory: Bool) {
        let item = Item(name: "", symbol: mandatory ? "tag.fill" : "star.fill", color: mandatory ? .gray : .lavender,
                        categoryID: BuiltInCategory.other.id, mandatory: mandatory, day: mandatory ? 25 : (paydays.first ?? 10),
                        custom: true)
        FolkiFeedback.selection()
        withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) { draft = item; draftIsNew = true }
    }

    private func open(_ item: Item) {
        FolkiFeedback.selection()
        withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) { draft = item; draftIsNew = false }
    }

    private func commitDraft() {
        guard let draft else { return }
        FolkiFeedback.saved()
        withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) {
            if let index = items.firstIndex(where: { $0.id == draft.id }) { items[index] = draft } else { items.append(draft) }
            self.draft = nil
        }
    }

    /// Nothing changes until the envelope is added or confirmed.
    private func closeDraft() {
        withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) { draft = nil }
    }

    private func remove(_ id: UUID) {
        FolkiFeedback.boundary()
        withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) {
            if draft?.id == id { draft = nil }
            items.removeAll { $0.id == id }
        }
    }

    private func go(back: Bool = false) {
        guard let index = steps.firstIndex(of: step) else { return }
        let target = back ? max(0, index - 1) : min(steps.count - 1, index + 1)
        draft = nil
        scrolled = false
        forward = !back
        withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) { step = steps[target] }
    }

    private func primary() {
        guard canContinue else { return }
        errorMessage = nil
        switch step {
        case .done:
            if hasFamily {
                do { try family.setContributionPercent(Int(percent), forEveryone: forEveryone) }
                catch { errorMessage = String(localized: "Не получилось сохранить процент. Попробуй ещё раз."); return }
            }
            save()
        default:
            FolkiFeedback.selection(); go()
        }
    }

    private static let incomeKey = "FolkiPlanIncome"

    private func exit() {
        if let cancel { cancel(); return }
        loaded = false; draft = nil; incomeText = ""; usesBalance = false; settings = PlanSettings.load()
        load()
        forward = false
        withAnimation(FolkiMotion.quick) { step = steps[0] }
    }

    private func save() {
        guard !over else { return }
        do {
            // Envelopes removed from the list leave the plan.
            for envelope in personal.envelopes where !items.contains(where: { $0.id == envelope.id && $0.minor > 0 }) {
                try personal.archiveEnvelope(envelope)
            }
            for item in items where item.minor > 0 {
                let size = Money(minorUnits: item.minor)
                // Savings are jars: one contribution per income, collected up to the goal.
                let goal = item.mandatory ? nil : Money(minorUnits: max(item.typed, item.minor))
                var existing = item.existing ? personal.envelopes.first(where: { $0.id == item.id }) : nil
                var carried = Money(minorUnits: 0)
                if let envelope = existing, envelope.isSavings != !item.mandatory {
                    // An older optional payment becomes a jar: its money moves into the new jar.
                    carried = Money(minorUnits: min(personal.envelopeBalance(envelope).minorUnits, (goal ?? size).minorUnits))
                    try personal.archiveEnvelope(envelope)
                    existing = nil
                }
                if let envelope = existing {
                    let due = envelope.dueDay == item.day ? envelope.nextDue
                        : try EnvelopeSchedule.firstDue(day: item.day, onOrAfter: personal.referenceDate, calendar: calendar)
                    try personal.updateEnvelope(envelope.with(name: item.name, size: size, dueDay: item.day, nextDue: due,
                        isMandatory: item.mandatory, symbol: item.symbol, color: item.color, target: goal))
                } else {
                    let due = try EnvelopeSchedule.firstDue(day: item.day, onOrAfter: personal.referenceDate, calendar: calendar)
                    _ = try personal.createEnvelope(name: item.name, size: size, nextDue: due, isMandatory: item.mandatory,
                        categoryID: item.categoryID, symbol: item.symbol, color: item.color,
                        kind: item.mandatory ? .payment : .savings, target: goal,
                        id: item.existing ? UUID() : item.id, initialFunding: carried)
                }
            }
            settings.save()
            let settings = settings
            Task {
                if settings.usesNotifications { _ = await PlanReminders.requestPermission() }
                await PlanReminders.reschedule(settings, sessions: [personal, family])
            }
            UserDefaults.standard.set(income, forKey: Self.incomeKey)
            FolkiFeedback.saved()
            if personal.availableForDailySpending.minorUnits > 0 {
                finish(!personal.envelopes.isEmpty)
            } else { finish(false) }
        } catch {
            errorMessage = String(localized: "Не получилось сохранить план. Уже сохранённые конверты останутся; можно повторить")
        }
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        if UserDefaults.standard.data(forKey: "FolkiPlanSettings") == nil, case .off = settings.income {
            // Never set up: suggest the payday the budget already knows.
            let day = personal.household.map { calendar.component(.day, from: $0.period.endExclusive) } ?? 10
            settings.income = .monthly([day])
        }
        if step == .hello && !startsWithHello { step = steps[0] }
        let saved = UserDefaults.standard.integer(forKey: Self.incomeKey)
        if saved > 0 { incomeText = String(saved / 100) }
        items = personal.envelopes.map { envelope in
            var item = Item(id: envelope.id, existing: true, name: envelope.name, symbol: envelope.symbol ?? "tag.fill",
                            color: envelope.color ?? .blue, categoryID: envelope.categoryID ?? BuiltInCategory.other.id,
                            mandatory: envelope.isMandatory && !envelope.isSavings, amount: MoneyText.input(envelope.size),
                            day: envelope.dueDay, months: 1)
            // A jar comes back with its goal and its contribution, not just one month of it.
            if let target = envelope.target {
                item.amount = MoneyText.input(target)
                item.monthly = MoneyText.input(envelope.size)
                item.byMonthly = true
            }
            return item
        }
    }
}

/// Recovery changes the proposed plan, never creates an income transaction or moves existing cash.
private struct PlanRecoveryView: View {
    let capacity: PlanCapacity
    let available: Int64
    @Binding var usesBalance: Bool
    let increaseIncome: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.xs) {
            if capacity.shortfall > 0 {
                LabeledContent("Не хватает", value: MoneyText.whole(Money(minorUnits: capacity.shortfall).roundedUpToWholeUnits))
                    .font(FolkiFont.headline).foregroundStyle(Color.folkiWarning)
                    .contentTransition(.numericText())
                if let recommended = capacity.recommendedIncome, recommended > capacity.income {
                    Button { increaseIncome(recommended) } label: {
                        Label("Доход + \(MoneyText.whole(Money(minorUnits: recommended - capacity.income)))", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(FolkiSoftButtonStyle())
                }
            }
            if available > 0 {
                Toggle(isOn: $usesBalance) {
                    Text("Учесть остаток \(MoneyText.whole(Money(minorUnits: available)))")
                        .font(FolkiFont.label).monospacedDigit()
                }.tint(Color.folkiAccent)
            }
            if capacity.balanceUsed > 0 {
                Text("Из остатка \(MoneyText.whole(Money(minorUnits: capacity.balanceUsed).roundedUpToWholeUnits)) · только на этот период")
                    .folkiText(.footnote).monospacedDigit()
            }
        }
        .padding(FolkiSpacing.card)
        .folkiTileBackground()
    }
}

// MARK: - Parts

/// Income as one bar: every envelope bites off a coloured piece, the rest is money to live on.
private struct IncomeBar: View {
    let income: Int64
    let items: [PlanWizardView.Item]
    let over: Bool
    var body: some View {
        GeometryReader { geometry in
            let filled = items.filter { $0.minor > 0 }
            let total = max(income, filled.reduce(0) { $0 + $1.minor })
            let width = geometry.size.width - CGFloat(filled.count) * 3
            HStack(spacing: FolkiSpacing.xxs) {
                ForEach(filled) { item in
                    let share = CGFloat(item.minor) / CGFloat(max(1, total))
                    RoundedRectangle(cornerRadius: 7).fill(item.color.color.gradient)
                        .frame(width: max(4, width * share))
                        .transition(.scale(scale: 0.2, anchor: .trailing).combined(with: .opacity))
                }
                RoundedRectangle(cornerRadius: 7)
                    .fill(over ? Color.folkiOver.gradient : Color.folkiAccent.gradient)
                    .frame(minWidth: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct Shake: GeometryEffect {
    var phase: CGFloat
    var animatableData: CGFloat { get { phase } set { phase = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(phase * .pi * 6), y: 0))
    }
}

/// One row of the plan list; a tap opens it on top for changes.
private struct ItemRow: View {
    let item: PlanWizardView.Item
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: FolkiSpacing.item) {
                CategoryIcon(symbol: item.symbol, color: item.color.color, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name).font(FolkiFont.headline).foregroundStyle(Color.folkiInk).lineLimit(1)
                    Text(item.mandatory ? String(localized: "\(item.day)-го")
                         : String(localized: "\(MoneyText.whole(Money(minorUnits: item.minor))) в месяц · \(PlanTerm.text(item.reachMonths))"))
                        .folkiText(.footnote).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(MoneyText.whole(Money(minorUnits: item.typed)))
                    .font(FolkiFont.moneyCard).monospacedDigit()
                    .foregroundStyle(item.color.color)
            }
            .frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(FolkiPressStyle(scale: 0.98))
    }
}

/// Adding or changing one envelope, in its own sheet laid out like a spend:
/// amount on the keypad, day or term on a wheel, and the effect on the day.
private struct DraftSheet: View {
    @Binding var item: PlanWizardView.Item
    let isNew: Bool
    let free: Int64
    /// A suggested goal for the cushion, zero for every other envelope.
    let cushionTarget: Int64
    let daily: Int64
    let over: Bool
    let recoveryVisible: Bool
    let recovery: () -> PlanRecoveryView
    let commit: () -> Void
    let cancel: () -> Void
    let remove: () -> Void
    @FocusState private var naming: Bool
    /// A new envelope of one's own is named first, with the system keyboard, and only then
    /// gets its amount on the Folki keypad: the two keyboards never share the screen.
    @State private var namingStep = false
    @State private var pickingIcon = false
    /// Which amount the keypad types into: the goal or the monthly sum.
    @State private var typingMonthly = false
    private var valid: Bool {
        item.typed > 0 && item.minor > 0 && !item.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group { if namingStep { nameStep } else { amountStep } }
            .background { FolkiBackground() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: cancel) { Image(systemName: "xmark") }.accessibilityLabel("Закрыть")
                }
                if !namingStep { ToolbarItem(placement: .principal) { header } }
            }
            .sheet(isPresented: $pickingIcon) {
                IconPickerSheet(symbol: $item.symbol, color: $item.color).presentationDetents([.medium, .large])
            }
            .onAppear { if item.custom && item.name.isEmpty { namingStep = true } }
            .animation(FolkiMotion.quick, value: item.byMonthly)
            .animation(FolkiMotion.standard, value: namingStep)
        }
        .interactiveDismissDisabled(item.typed > 0)
    }

    private var trimmedName: String { item.name.trimmingCharacters(in: .whitespaces) }

    /// Step one for an envelope of one's own: icon and name.
    private var nameStep: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.page) {
            Text(item.mandatory ? "Что за платёж?" : "На что копим?").font(FolkiFont.title)
            HStack(spacing: FolkiSpacing.item) {
                Button { pickingIcon = true } label: {
                    CategoryIcon(symbol: item.symbol, color: item.color.color, size: 56)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil.circle.fill").font(FolkiFont.symbol(18)).foregroundStyle(.white, Color.folkiAccent)
                        }
                }.buttonStyle(.plain).accessibilityLabel("Значок и цвет")
                TextField(item.mandatory ? "Например, аренда" : "Например, отпуск", text: $item.name)
                    .font(FolkiFont.headline).focused($naming).submitLabel(.next)
                    .onSubmit(finishNaming)
            }
            .padding(FolkiSpacing.item)
            .folkiTileBackground()
            Spacer(minLength: 0)
            Button("Дальше", action: finishNaming).buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                .disabled(trimmedName.isEmpty)
        }
        .padding(.horizontal, FolkiSpacing.page).padding(.top, FolkiSpacing.card).padding(.bottom, FolkiSpacing.card)
        .onAppear { naming = true }
    }

    private func finishNaming() {
        guard !trimmedName.isEmpty else { FolkiFeedback.boundary(); return }
        naming = false
        namingStep = false
    }

    /// Step two, or the only step for a template: the amount on the Folki keypad.
    private var amountStep: some View {
            FolkiEntryLayout { _ in
                VStack(spacing: FolkiSpacing.page) {
                    if item.mandatory {
                        amount(item.amount, label: String(localized: "Ожидаемый платёж"), active: true) {}
                        Text("Сумма для планирования. При оплате можно указать фактическую — больше или меньше.")
                            .folkiText(.footnote).multilineTextAlignment(.center)
                    } else if item.byMonthly {
                        HStack(spacing: FolkiSpacing.item) {
                            amount(item.amount, label: String(localized: "Цель"), active: !typingMonthly, small: true) { typingMonthly = false }
                            amount(item.monthly, label: String(localized: "В месяц"), active: typingMonthly, small: true) { typingMonthly = true }
                        }
                    } else {
                        amount(item.amount, label: String(localized: "Цель"), active: true) {}
                    }
                    if cushionTarget > 0 && item.typed != cushionTarget {
                        // A number to start from instead of a guess: the usual cushion is three months of spending.
                        Button {
                            FolkiFeedback.selection(); typingMonthly = false
                            item.amount = MoneyText.input(Money(minorUnits: cushionTarget))
                        } label: {
                            Text("3 месяца расходов · \(MoneyText.whole(Money(minorUnits: cushionTarget)))")
                                .font(FolkiFont.label).monospacedDigit()
                                .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 40)
                                .glassEffect(.regular.interactive(), in: Capsule())
                        }.buttonStyle(FolkiPressStyle()).foregroundStyle(item.color.color)
                    }
                    if !item.mandatory {
                        FolkiSegmentedPicker(title: String(localized: "Как копить"), selection: $item.byMonthly,
                            options: [(String(localized: "К сроку"), false), (String(localized: "Своей суммой"), true)])
                        .onChange(of: item.byMonthly) { _, monthly in typingMonthly = monthly && item.typed > 0 }
                    }
                    result
                    if recoveryVisible { recovery() }
                    if item.mandatory {
                        wheel(String(localized: "День оплаты"), selection: $item.day, values: Array(1...31)) { "\($0)-го" }
                    } else if !item.byMonthly {
                        wheel(String(localized: "Срок"), selection: $item.months, values: [3, 6, 12, 24, 36, 60, 120]) { PlanTerm.text($0) }
                    }
                    if !isNew {
                        Button("Убрать из плана", systemImage: "trash", role: .destructive) { remove() }
                            .font(FolkiFont.label)
                    }
                }
                .padding(.horizontal, FolkiSpacing.page)
            } keypad: {
                VStack(spacing: 12) {
                    AmountKeypad(text: typingMonthly && item.byMonthly ? $item.monthly : $item.amount)
                    Button(isNew ? String(localized: "Добавить") : String(localized: "Готово"), action: commit)
                        .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(!valid)
                }
                .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
            }
    }

    /// The icon (tap to change it and its colour) and the name, at the top.
    private var header: some View {
        HStack(spacing: FolkiSpacing.item) {
            Button { naming = false; pickingIcon = true } label: {
                CategoryIcon(symbol: item.symbol, color: item.color.color, size: 30)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill").font(FolkiFont.symbol(12)).foregroundStyle(.white, Color.folkiAccent)
                            .offset(x: 3, y: 3)
                    }
            }
            .buttonStyle(.plain).accessibilityLabel("Значок и цвет")
            if item.custom {
                // The name was typed on the first step; a tap goes back to it.
                Button { namingStep = true } label: { Text(item.name).font(FolkiFont.headline).lineLimit(1) }
                    .buttonStyle(.plain).accessibilityHint("Изменить название")
            } else {
                Text(item.name).font(FolkiFont.headline).lineLimit(1)
            }
        }
    }

    private func amount(_ text: String, label: String?, active: Bool, small: Bool = false, select: @escaping () -> Void) -> some View {
        Button { naming = false; select() } label: {
            VStack(spacing: FolkiSpacing.xxs) {
                if let label { Text(label).folkiText(.tag) }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TypedAmount(text: text)
                    Text("₽").foregroundStyle(Color.folkiSecondary)
                }
                .font(FolkiFont.money(small ? 32 : FolkiFont.inputSize))
                .foregroundStyle(text.isEmpty ? Color.secondary : item.color.color)
            }
            .frame(maxWidth: .infinity).padding(.vertical, small ? 10 : 0)
            .background {
                if small {
                    RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius).fill(Color.folkiTile)
                        .overlay { RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius).strokeBorder(item.color.color, lineWidth: active ? 2 : 0) }
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// What the numbers mean: the day after this envelope, and for savings the monthly sum or the time to the goal.
    private var result: some View {
        VStack(spacing: 4) {
            if !item.mandatory && item.minor > 0 && item.typed > 0 {
                Text(item.byMonthly ? String(localized: "Накопишь за \(PlanTerm.text(item.reachMonths))")
                     : String(localized: "Откладывать \(MoneyText.whole(Money(minorUnits: item.minor))) в месяц"))
                    .font(FolkiFont.headline).monospacedDigit().foregroundStyle(item.color.color)
                    .contentTransition(.numericText())
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Останется ≈ \(MoneyText.whole(Money(minorUnits: daily)))")
                    .font(FolkiFont.label).monospacedDigit()
                    .contentTransition(.numericText(value: Double(daily)))
                Text("в день").folkiText(.caption)
            }
            .foregroundStyle(over ? Color.folkiOver : Color.folkiInk)
        }
        .padding(.vertical, 12).frame(maxWidth: .infinity)
        .folkiGlassBackground()
    }

    private func wheel(_ label: String, selection: Binding<Int>, values: [Int], text: @escaping (Int) -> String) -> some View {
        HStack {
            Text(label).font(FolkiFont.label).foregroundStyle(Color.folkiSecondary)
            Picker(label, selection: selection) {
                ForEach(values, id: \.self) { Text(text($0)).tag($0) }
            }
            .pickerStyle(.wheel).frame(height: 110).clipped()
            .sensoryFeedback(.selection, trigger: selection.wrappedValue)
        }
    }
}

enum PlanTerm {
    static func text(_ months: Int) -> String {
        if months < 12 { return String(localized: "\(months) мес") }
        if months % 12 != 0 && months < 36 { return String(localized: "\(months) мес") }
        let years = (months + 6) / 12
        return years == 1 ? String(localized: "1 год") : years < 5 ? String(localized: "\(years) года") : String(localized: "\(years) лет")
    }
}

/// Keypad digits as they are typed: a new digit rises in at the end, an erased one leaves from the end.
/// Each digit keeps its identity by its order, so thousand separators never make the others jump.
struct TypedAmount: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct Glyph: Identifiable { let id: String; let character: Character }
    private var glyphs: [Glyph] {
        let shown = text.isEmpty ? "0" : MoneyText.grouped(text)
        var digit = 0, result: [Glyph] = []
        for character in shown {
            if character.isNumber || character == "," {
                result.append(Glyph(id: "d\(digit)", character: character)); digit += 1
            } else {
                result.append(Glyph(id: "s\(digit)", character: character))
            }
        }
        return result
    }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(glyphs) { glyph in
                Text(String(glyph.character)).monospacedDigit()
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: 18).combined(with: .opacity).combined(with: .scale(scale: 0.6, anchor: .bottom)),
                        removal: .offset(y: -10).combined(with: .opacity).combined(with: .scale(scale: 0.6))))
            }
        }
        .lineLimit(1).minimumScaleFactor(0.5)
        .animation(reduceMotion ? nil : FolkiMotion.quick, value: text)
        .accessibilityElement().accessibilityLabel(text.isEmpty ? "0" : MoneyText.grouped(text))
    }
}
