import SwiftUI
import FolkiDuoCore

/// First launch: hello → how to start → money to live on → what Folki does → the main screen.
/// Invited people wait for their link; people with a Folki elsewhere restore from iCloud.
struct OnboardingView: View {
    let personal: BudgetSession
    let family: BudgetSession
    /// Called when the main screen should appear.
    let finish: () -> Void

    enum Step: String { case hello, start, budget, features, invited, restore }
    @AppStorage("FolkiOnboardingStep") private var savedStep = Step.hello.rawValue
    @State private var step: Step = .hello
    @State private var history: [Step] = []
    @State private var forward = true
    @State private var invited = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 56).padding(.horizontal, FolkiSpacing.page)
            ZStack {
                page.id(step).transition(transition)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }
        .background { FolkiBackground() }
        .onAppear { step = Step(rawValue: savedStep) ?? .hello }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .hello: HelloPage { go(.start) }
        case .start: StartPage(family: family) { choice in
            switch choice {
            case .fresh: invited = false; go(.budget)
            case .invited: go(.invited)
            case .restore: go(.restore)
            }
        }
        // Money is saved on this step, so there is no way back to it.
        case .budget: BudgetStartPage(personal: personal, invited: invited) { go(.features, keepingHistory: false) }
        case .features: FeaturesPage(invited: invited, done: finish)
        case .invited: InvitedPage(family: family) { joined in invited = joined; go(.budget) }
        case .restore: RestorePage(personal: personal, done: finish) { go(.budget) }
        }
    }

    private var header: some View {
        HStack {
            if !history.isEmpty {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Назад")
                .transition(.opacity)
            }
            Spacer()
        }.animation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion), value: history.isEmpty)
    }

    private func go(_ next: Step, keepingHistory: Bool = true) {
        forward = true
        withAnimation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion)) {
            if keepingHistory { history.append(step) } else { history.removeAll() }
            step = next
        }
        savedStep = next.rawValue
    }
    private func back() {
        guard let previous = history.last else { return }
        forward = false
        withAnimation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion)) {
            history.removeLast(); step = previous
        }
        savedStep = previous.rawValue
    }
}

// MARK: - Pages

/// A page with content at the top and the actions pinned to the bottom.
private struct OnboardingPage<Content: View, Actions: View>: View {
    var centered = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView {
                    content().frame(maxWidth: FolkiSpacing.maxWidth).padding(.horizontal, FolkiSpacing.page)
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: centered ? .center : .top)
                }.scrollBounceBehavior(.basedOnSize)
            }
            VStack(spacing: FolkiSpacing.item) { actions() }
                .frame(maxWidth: FolkiSpacing.maxWidth)
                .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.xs)
        }
    }
}

/// Cascading rise: fade in and lift 8 points, one item after another.
private struct Rise: ViewModifier {
    let order: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                withAnimation(FolkiMotion.resolved(FolkiMotion.hero, reduceMotion: reduceMotion)
                    .delay(reduceMotion ? 0 : FolkiMotion.cascadeStep * Double(order))) { shown = true }
            }
    }
}
private extension View { func rise(_ order: Int) -> some View { modifier(Rise(order: order)) } }

private struct HelloPage: View {
    let next: () -> Void
    var body: some View {
        OnboardingPage(centered: true) {
            VStack(spacing: FolkiSpacing.large) {
                AnimatedHouse().frame(width: 220, height: 220)
                VStack(spacing: FolkiSpacing.item) {
                    Text("Привет! Я Folki 👋")
                        .font(.largeTitle.bold()).rise(8)
                    Text("Твой помощник с финансами")
                        .font(.body).foregroundStyle(.secondary).rise(9)
                }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.padding(.bottom, FolkiSpacing.huge)
        } actions: {
            Button("Начать", action: next).buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).rise(10)
        }
    }
}

private enum StartChoice { case fresh, invited, restore }

private struct StartPage: View {
    let family: BudgetSession
    let choose: (StartChoice) -> Void
    var body: some View {
        OnboardingPage(centered: true) {
            VStack(spacing: FolkiSpacing.large) {
                FamilyBubbles(family: family) { FolkiFeedback.selection(); choose(.invited) }.frame(height: 290)
                VStack(spacing: FolkiSpacing.item) {
                    Text("Вместе с близкими").font(.largeTitle.bold())
                    Text("Общие траты — вместе. Личные — только твои").font(.body).foregroundStyle(.secondary)
                }.multilineTextAlignment(.center).rise(3)
            }.padding(.bottom, FolkiSpacing.large)
        } actions: {
            Button("Начать с нуля") { FolkiFeedback.selection(); choose(.fresh) }
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).rise(4)
            Button { FolkiFeedback.selection(); choose(.invited) } label: {
                Label { Text("Меня пригласили") } icon: {
                    Image(systemName: "envelope").overlay {
                        Image(systemName: "heart.fill").font(.system(size: 7)).foregroundStyle(RingPalette.family.start)
                            .padding(2).background(Color(uiColor: .systemBackground), in: Circle())
                    }
                }.frame(maxWidth: .infinity)
            }.buttonStyle(FolkiSoftButtonStyle()).rise(5)
            Button("Восстановить из iCloud") { choose(.restore) }
                .font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 44).rise(6)
        }
    }
}

/// "Сколько денег на жизнь?": a period, an amount and the live daily figure. Mandatory: no skip.
private struct BudgetStartPage: View {
    let personal: BudgetSession
    let invited: Bool
    let next: () -> Void

    enum Length: String, CaseIterable { case payday, month, week }
    @State private var length: Length = .month
    @State private var payday = Date.now.addingTimeInterval(14 * 86_400)
    @State private var amount = ""
    @State private var shakes = 0
    @State private var errorMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { personal.calendar }
    private var today: Date { calendar.startOfDay(for: personal.referenceDate) }
    /// The start of the first day after the period.
    private var end: Date {
        switch length {
        case .month: calendar.date(byAdding: .day, value: 30, to: today)!
        case .week: calendar.date(byAdding: .day, value: 7, to: today)!
        case .payday: calendar.startOfDay(for: payday)
        }
    }
    private var days: Int { max(1, calendar.dateComponents([.day], from: today, to: end).day ?? 1) }
    private var money: Money? { (try? MoneyText.parse(amount)).flatMap { $0.minorUnits > 0 ? $0 : nil } }
    private var perDay: Money? { money.flatMap { try? DailyAllocation(total: $0, days: days).firstDayAmount } }

    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: 0) {
                Text(invited ? "Твой личный бюджет" : "Сколько денег на жизнь?").font(.largeTitle.bold())
                if invited {
                    Text("Его видишь только ты").font(.body).foregroundStyle(.secondary).padding(.top, FolkiSpacing.xs)
                }
                HStack(spacing: FolkiSpacing.xs) {
                    chip(.payday, "До зарплаты"); chip(.month, "Месяц"); chip(.week, "Неделя")
                }.padding(.top, FolkiSpacing.page)
                if length == .payday {
                    DatePicker("Зарплата", selection: $payday,
                               in: calendar.date(byAdding: .day, value: 1, to: today)!...calendar.date(byAdding: .day, value: 62, to: today)!,
                               displayedComponents: .date)
                        .font(.body).padding(.top, FolkiSpacing.item)
                }
                VStack(alignment: .leading, spacing: FolkiSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: FolkiSpacing.xs) {
                    Text(amount.isEmpty ? "0" : MoneyText.grouped(amount))
                        .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(amount.isEmpty ? .tertiary : .primary)
                        .contentTransition(.numericText()).animation(FolkiMotion.quick, value: amount)
                    Text(MoneyText.symbol).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.tertiary)
                }
                .lineLimit(1).minimumScaleFactor(0.4).fixedSize(horizontal: false, vertical: true)
                .keyframeAnimator(initialValue: 0.0, trigger: shakes) { view, offset in view.offset(x: offset) } keyframes: { _ in
                    KeyframeTrack { SpringKeyframe(-10, duration: 0.08); SpringKeyframe(10, duration: 0.08); SpringKeyframe(-6, duration: 0.08); SpringKeyframe(0, duration: 0.1) }
                }
                .accessibilityLabel("Сумма \(money.map(MoneyText.string) ?? "не введена")")
                Group {
                    if let perDay {
                        Text("≈ \(MoneyText.whole(perDay)) в день · \(days) дн.")
                            .contentTransition(.numericText()).animation(FolkiMotion.quick, value: perDay)
                    } else {
                        Text("Я разделю сумму на \(days) дн.").foregroundStyle(.secondary)
                    }
                }.font(.body.weight(.medium)).foregroundStyle(Color.folkiAccent)
                }
                .padding(FolkiSpacing.page).frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(Color.folkiAccent.opacity(0.08)).interactive(), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
                .padding(.top, FolkiSpacing.large)
                if let errorMessage { FolkiErrorMessage(message: errorMessage).padding(.top, FolkiSpacing.item) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, FolkiSpacing.page)
        } actions: {
            AmountKeypad(text: $amount)
            Button("Продолжить", action: save).buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        }
    }

    private func chip(_ value: Length, _ title: LocalizedStringKey) -> some View {
        let selected = length == value
        return Button {
            FolkiFeedback.selection()
            withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) { length = value }
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 40)
                .foregroundStyle(selected ? Color.white : Color.folkiInk)
                .glassEffect(.regular.tint(selected ? Color.folkiAccent : .clear).interactive(), in: Capsule())
        }.buttonStyle(FolkiPressStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        guard let money else { FolkiFeedback.boundary(); shakes += 1; return }
        do {
            try personal.startBudget(amount: money, until: end)
            FolkiFeedback.saved()
            next()
        } catch {
            errorMessage = String(localized: "Не получилось сохранить сумму. Попробуй ещё раз.")
        }
    }
}

/// "Вот что я умею": three rows, each with a small animation that plays once.
private struct FeaturesPage: View {
    let invited: Bool
    let done: () -> Void
    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: FolkiSpacing.large) {
                Text("Вот что я умею").font(.largeTitle.bold())
                row(SpendDemo(), "Ты тратишь — я пересчитываю", "Запиши трату, и остаток дня сразу поменяется").rise(1)
                row(RingsDemo(), "Общее и личное",
                    invited ? String(localized: "Ты в семейном бюджете: общее видят все, личное — только ты")
                        : String(localized: "Семья видит общее, твоё — только ты")).rise(2)
                row(EnvelopesDemo(), "Раскладываю по конвертам", "Аренда и интернет — отдельно, остальное — на жизнь").rise(3)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, FolkiSpacing.page)
        } actions: {
            Button("Перейти к Folki") { FolkiFeedback.saved(); done() }
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).rise(4)
        }
    }
    private func row<Art: View>(_ art: Art, _ title: LocalizedStringKey, _ text: String) -> some View {
        HStack(spacing: FolkiSpacing.card) {
            art.frame(width: 64, height: 64).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Waiting for the invitation link; joins automatically when it arrives.
private struct InvitedPage: View {
    let family: BudgetSession
    let next: (Bool) -> Void
    @State private var waitedLong = false
    @State private var showingHelp = false
    private var joined: Bool { family.household != nil && family.members.filter(\.isActive).count > 1 }
    private var cloudless: Bool { family.repository?.cloudIdentifier == nil && !family.isDemo }

    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: FolkiSpacing.page) {
                Image(systemName: "envelope.open").font(.system(size: 64)).foregroundStyle(Color.folkiAccent)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "heart.fill").font(.title3).foregroundStyle(RingPalette.family.start).offset(x: 8, y: -4)
                    }
                    .symbolEffect(.bounce, options: .nonRepeating)
                Text("Открой ссылку из сообщения").font(.largeTitle.bold())
                if cloudless {
                    Label("Эта сборка работает без iCloud, присоединиться к семье в ней нельзя.", systemImage: "icloud.slash")
                        .foregroundStyle(.secondary)
                } else {
                    step(1, "Попроси прислать приглашение в Folki")
                    step(2, "Открой ссылку на этом iPhone")
                    step(3, "Подключение произойдёт само")
                    status.padding(.top, FolkiSpacing.xs)
                    Button("Ссылка уже открыта, а ничего не происходит") { showingHelp.toggle() }
                        .font(.subheadline).foregroundStyle(Color.folkiAccent)
                    if showingHelp {
                        Text("Если Folki ставился по ссылке, открой ссылку из сообщения ещё раз — теперь приложение её примет.")
                            .font(.subheadline).foregroundStyle(.secondary).transition(.opacity)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, FolkiSpacing.page)
                .animation(FolkiMotion.quick, value: showingHelp)
        } actions: {
            if waitedLong || cloudless {
                Button("Пока начать с личного бюджета") { next(false) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(10))
            withAnimation(FolkiMotion.standard) { waitedLong = true }
        }
        .onChange(of: joined) { _, now in
            guard now else { return }
            FolkiFeedback.saved()
            Task { try? await Task.sleep(for: .seconds(1)); next(true) }
        }
    }

    @ViewBuilder private var status: some View {
        if joined {
            Label("Ты в семейном бюджете", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(Color.folkiAccent).transition(.scale.combined(with: .opacity))
        } else {
            HStack(spacing: FolkiSpacing.xs) {
                Circle().fill(Color.folkiAccent).frame(width: 8, height: 8).symbolEffect(.pulse)
                    .phaseAnimator([0.3, 1]) { dot, phase in dot.opacity(phase) } animation: { _ in .easeInOut(duration: 0.8) }
                Text("Жду приглашение…").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: FolkiSpacing.item) {
            Text("\(number)").font(.subheadline.bold()).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(Color.folkiAccent, in: Circle())
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Waits for this Apple ID's data to arrive from iCloud after a reinstall.
private struct RestorePage: View {
    let personal: BudgetSession
    let done: () -> Void
    let startFresh: () -> Void
    @State private var deadline = Date.now.addingTimeInterval(20)
    @State private var timedOut = false
    private var found: Bool { personal.household != nil }
    private var cloudOff: Bool { personal.repository?.cloudIdentity == nil && !personal.isDemo }

    var body: some View {
        OnboardingPage(centered: true) {
            VStack(spacing: FolkiSpacing.large) {
                AnimatedHouse(searching: !found).frame(width: 120, height: 120)
                VStack(spacing: FolkiSpacing.item) {
                    Text(title).font(.title2.bold())
                    if let detail { Text(detail).font(.body).foregroundStyle(.secondary) }
                }.multilineTextAlignment(.center)
            }.padding(.bottom, FolkiSpacing.huge)
        } actions: {
            if cloudOff {
                Button("Открыть настройки") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                Button("Начать с нуля", action: startFresh).font(.subheadline).frame(minHeight: 44)
            } else if timedOut && !found {
                Button("Подождать ещё") { deadline = .now.addingTimeInterval(30); timedOut = false }
                    .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                Button("Начать с нуля", action: startFresh).font(.subheadline).frame(minHeight: 44)
            }
        }
        .task(id: deadline) {
            try? await Task.sleep(until: .now + .seconds(max(0, deadline.timeIntervalSinceNow)))
            if !found { withAnimation(FolkiMotion.standard) { timedOut = true } }
        }
        .onChange(of: found) { _, now in
            guard now else { return }
            FolkiFeedback.saved()
            Task { try? await Task.sleep(for: .seconds(1)); done() }
        }
    }

    private var title: String {
        if cloudOff { return String(localized: "iCloud выключен — данные не восстановить") }
        if found { return String(localized: "Готово: \(personal.historyRecords.count) трат") }
        if timedOut { return String(localized: "Пока ничего не вижу") }
        return String(localized: "Ищу твои данные в iCloud…")
    }
    private var detail: String? {
        if timedOut && !found && !cloudOff {
            return String(localized: "Проверь, что на этом iPhone тот же Apple ID и для Folki включён iCloud")
        }
        return nil
    }
}

// MARK: - Mini animations

private struct SpendDemo: View {
    @State private var spent = false
    var body: some View {
        ZStack {
            Circle().stroke(RingPalette.personal.start.opacity(0.18), lineWidth: 6)
            Circle().trim(from: 0, to: spent ? 0.45 : 0.75)
                .stroke(RingPalette.personal.start, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
            Text(spent ? "790" : "1 240").font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(4)
        .task { try? await Task.sleep(for: .seconds(0.6)); withAnimation(FolkiMotion.ring) { spent = true } }
    }
}

private struct RingsDemo: View {
    @State private var shown = false
    var body: some View {
        ZStack {
            ring(RingPalette.personal.start, 0.8).padding(4)
            ring(RingPalette.family.start, 0.55).padding(14)
        }.task { try? await Task.sleep(for: .seconds(0.7)); withAnimation(FolkiMotion.ring) { shown = true } }
    }
    private func ring(_ color: Color, _ value: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 6)
            Circle().trim(from: 0, to: shown ? value : 0).stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct EnvelopesDemo: View {
    @State private var split = false
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 4).fill(Color.folkiWarning).frame(width: split ? geo.size.width * 0.35 : 0)
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.5)).frame(width: split ? geo.size.width * 0.12 : 0)
                RoundedRectangle(cornerRadius: 4).fill(Color.folkiAccent)
            }.frame(height: 20).frame(maxHeight: .infinity)
        }.task { try? await Task.sleep(for: .seconds(0.8)); withAnimation(FolkiMotion.ring) { split = true } }
    }
}

/// The icon's house: the walls stand still, and the two roof stripes fill in like the rings.
private struct AnimatedHouse: View {
    /// While searching, the roofs keep filling and emptying.
    var searching = false
    @State private var outer: CGFloat = 0
    @State private var inner: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let style = StrokeStyle(lineWidth: w * 0.09, lineCap: .round, lineJoin: .round)
            ZStack {
                IconRoof(inner: false).stroke(RingPalette.personal.start.opacity(0.12), style: style)
                IconRoof(inner: false).trim(from: 0, to: outer)
                    .stroke(RingPalette.personal.start, style: style)
                IconRoof(inner: true).stroke(RingPalette.family.start.opacity(0.12), style: style)
                IconRoof(inner: true).trim(from: 0, to: inner)
                    .stroke(RingPalette.family.start, style: style)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: w * 0.057).fill(scheme == .dark ? Color.white : Color(red: 0.09, green: 0.29, blue: 0.23))
                    UnevenRoundedRectangle(topLeadingRadius: w * 0.047, topTrailingRadius: w * 0.047)
                        .frame(width: w * 0.094, height: w * 0.137).blendMode(.destinationOut)
                }.compositingGroup().frame(width: w * 0.41, height: w * 0.225)
                    .position(x: w * 0.5, y: w * 0.678)
            }
        }
        .onAppear(perform: play)
        .accessibilityHidden(true)
    }

    private func play() {
        guard !reduceMotion else { outer = 1; inner = 1; return }
        if searching {
            withAnimation(.easeInOut(duration: 1.2).repeatForever()) { outer = 1 }
            withAnimation(.easeInOut(duration: 1.2).delay(0.3).repeatForever()) { inner = 1 }
            return
        }
        withAnimation(.easeInOut(duration: 0.9).delay(0.2)) { outer = 1 }
        withAnimation(.easeInOut(duration: 0.8).delay(0.55)) { inner = 1 }
    }
}

private struct IconRoof: Shape {
    var inner: Bool
    func path(in rect: CGRect) -> Path {
        let left: CGFloat = inner ? 0.293 : 0.176
        let y: CGFloat = inner ? 0.53 : 0.483
        let peak: CGFloat = inner ? 0.359 : 0.217
        var path = Path()
        path.move(to: CGPoint(x: rect.width * left, y: rect.height * y))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.height * peak))
        path.addLine(to: CGPoint(x: rect.width * (1 - left), y: rect.height * y))
        return path
    }
}

