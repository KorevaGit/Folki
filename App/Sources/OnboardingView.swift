import SwiftUI
import FolkiDuoCore

/// Four short pages. Every setup action can be skipped; navigation animates local state.
struct OnboardingView: View {
    let personal: BudgetSession
    let family: BudgetSession
    let finish: () -> Void
    @AppStorage("FolkiOnboardingStep") private var savedPage = 0
    @State private var page = min(3, max(0, UserDefaults.standard.integer(forKey: "FolkiOnboardingStep")))
    @AppStorage("FolkiOnboardingDailyPersonal") private var personalAmount = ""
    @AppStorage("FolkiOnboardingDailyFamily") private var familyAmount = ""
    @State private var forward = true
    @State private var transitioning = false
    @State private var editingScope: BudgetScope?
    @State private var showingFamily = false
    @State private var showingJoin = false
    @State private var showingDistribution = false
    @State private var showingFullFinance = false
    @State private var showingExpense = false
    @State private var errorMessage: String?
    @State private var day = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hasFamily: Bool { family.household != nil }
    private var step: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 56).padding(.top, 12).padding(.horizontal, FolkiSpacing.page)
            ZStack {
                content.id(page).transition(step).zIndex(1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            if let errorMessage { FolkiErrorMessage(message: errorMessage).padding(.horizontal, FolkiSpacing.page) }
            Group {
                if let editingScope {
                    VStack(spacing: 12) {
                        AmountKeypad(text: editingScope == .personal ? $personalAmount : $familyAmount)
                        Button("Готово") { edit(nil) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                    }.transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    VStack(spacing: 0) { footer }.id(page).transition(.opacity)
                        .allowsHitTesting(!transitioning)
                }
            }.padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
                .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: editingScope)
        }
        .background { FolkiBackground() }
        .sheet(isPresented: $showingFamily) { SharingView(session: family) }
        .sheet(isPresented: $showingJoin) { JoinFamilyView(family: family).presentationDetents([.medium]) }
        .sheet(isPresented: $showingDistribution) {
            DistributionChoiceView(day: $day, apply: { value in
                try personal.setDistributionDay(value)
                if hasFamily { try family.setDistributionDay(value) }
            })
        }
        .sheet(isPresented: $showingFullFinance) { BudgetSetupView(session: personal, editingCurrent: true) }
        .sheet(isPresented: $showingExpense) { QuickSpendView(personal: personal, family: family) }
        .onAppear { day = personal.distributionDay }
    }
    @ViewBuilder private var content: some View {
        switch page {
        case 0:
            illustration(title: "Привет! Это Folki 👋", text: "Сколько можно потратить сегодня.") {
                AnimatedHouse().frame(width: 210, height: 190)
            }
        case 1:
            illustration(title: "Вместе с близкими", text: "Общие траты — вместе. Личные — только твои.") {
                FamilyBubbles(family: family) { createFamily() }.frame(height: 250)
            } extra: {
                Button("Меня пригласили") { showingJoin = true }.buttonStyle(FolkiSoftButtonStyle())
            }
        case 2: moneyPage
        default:
            illustration(title: "Первая трата", text: "Уже что-нибудь потратил сегодня?") {
                Image(systemName: "basket.fill").font(.system(size: 96)).foregroundStyle(Color.folkiAccent)
                    .frame(height: 180).folkiAppear()
            } extra: {
                Button("Записать трату") { showingExpense = true }.buttonStyle(FolkiSoftButtonStyle())
            }
        }
    }
    private var header: some View {
        ZStack {
            if page > 0 {
                HStack(spacing: 8) {
                    ForEach(1...3, id: \.self) { i in
                        Capsule().fill(i == page ? Color.folkiAccent : Color.folkiInk.opacity(0.12))
                            .frame(width: i == page ? 24 : 8, height: 8)
                    }
                }.animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: page)
                    .accessibilityLabel("Шаг \(page) из 3")
                HStack {
                    Button { go(page - 1) } label: {
                        Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Назад")
                    Spacer()
                }
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: page > 0)
    }
    private var moneyPage: some View {
        pageScroll(centered: false) {
            VStack(alignment: .leading, spacing: 22) {
                Text("На каждый день").font(.system(.largeTitle, design: .rounded, weight: .bold))
                if hasFamily {
                    amountRow("Личные", text: personalAmount, scope: .personal)
                    amountRow("Семейные", text: familyAmount, scope: .family)
                } else {
                    amountRow("Сколько выделишь на повседневные траты?", text: personalAmount, scope: .personal)
                }
                Button { showingDistribution = true } label: {
                    HStack {
                        Text("Распределить")
                        Spacer()
                        Text(distributionTitle(day)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.down").font(.caption)
                    }.font(.subheadline)
                }.buttonStyle(.plain)
                Button("Хочу вести все финансы") {
                    do {
                        try personal.setDistributionDay(day); try personal.ensureDailyPeriod()
                        personal.fullFinanceEnabled = true; showingFullFinance = true
                    } catch { errorMessage = String(localized: "Не получилось открыть бюджет. Попробуй ещё раз.") }
                }.font(.subheadline).foregroundStyle(Color.folkiAccent)
            }.padding(.vertical, 16).folkiAppear(1)
        }
    }
    private func amountRow(_ title: LocalizedStringKey, text: String, scope: BudgetScope) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Button { edit(scope) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(text.isEmpty ? "0" : text).font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(text.isEmpty ? 1 : 0.4).layoutPriority(1)
                        .contentTransition(text.isEmpty ? .identity : .numericText())
                    Text(MoneyText.symbol).font(.title).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding(18).glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
            }.buttonStyle(.plain)
        }
    }
    @ViewBuilder private var footer: some View {
        switch page {
        case 0:
            Button("Поехали") { go(1) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            footerSpace
        case 1:
            Button(hasFamily ? "Дальше" : "Создать семью") { hasFamily ? go(2) : createFamily() }
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            Button("Настрою позже") { go(2) }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
        case 2:
            Button("Продолжить", action: saveFunds).buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            Button("Добавлю позже") { go(3) }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
        default:
            Button("Начать") {
                personalAmount = ""; familyAmount = ""; FolkiFeedback.success(); finish()
            }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            footerSpace
        }
    }
    private var footerSpace: some View { Text(" ").font(.subheadline).padding(.top, 8).accessibilityHidden(true) }
    private func go(_ next: Int) {
        guard !transitioning else { return }
        transitioning = true
        forward = next > page; FolkiFeedback.selection()
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.15)) { editingScope = nil; page = next }
        savedPage = next; errorMessage = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            transitioning = false
        }
    }
    private func edit(_ scope: BudgetScope?) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) { editingScope = scope }
    }
    private func createFamily() {
        do { try family.ensureDailyPeriod(); showingFamily = true }
        catch { errorMessage = String(localized: "Не получилось создать семью. Попробуй ещё раз.") }
    }
    private func saveFunds() {
        do {
            let entries: [(BudgetSession, String)] = [(personal, personalAmount)] + (hasFamily ? [(family, familyAmount)] : [])
            // Parse both before saving either; clear each successful input to make retries safe.
            let parsed = try entries.map { ($0.0, $0.1.isEmpty ? nil : try MoneyText.parse($0.1)) }
            guard parsed.allSatisfy({ $0.1 == nil || $0.1!.minorUnits > 0 }) else { throw BudgetError.invalidAmount }
            for (session, amount) in parsed {
                try session.setDistributionDay(day)
                if let amount {
                    try session.addDailyFunds(amount)
                    if session.scope == .personal { personalAmount = "" } else { familyAmount = "" }
                }
            }
            go(3)
        } catch { errorMessage = String(localized: "Проверь сумму и попробуй ещё раз.") }
    }
    private func pageScroll<Content: View>(centered: Bool, @ViewBuilder content: () -> Content) -> some View {
        let pageBody = content()
        return GeometryReader { viewport in
            ScrollView {
                pageBody.frame(maxWidth: FolkiSpacing.maxWidth).padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: centered ? .center : .top)
            }.scrollBounceBehavior(.basedOnSize)
        }
    }
    private func illustration<Art: View, Extra: View>(title: LocalizedStringKey, text: LocalizedStringKey,
        @ViewBuilder art: () -> Art, @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        pageScroll(centered: true) {
            VStack(spacing: 28) {
                art()
                VStack(spacing: 12) {
                    Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    extra()
                }.folkiAppear(page == 0 ? 8 : 3)
            }.multilineTextAlignment(.center).padding(.vertical, 20)
        }
    }
}

/// How to join someone else's family budget: open their invite link, and Folki connects on its own.
private struct JoinFamilyView: View {
    let family: BudgetSession
    @Environment(\.dismiss) private var dismiss
    private var joined: Bool { family.members.filter(\.isActive).count > 1 }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if family.repository?.cloudIdentifier == nil {
                    Label("Эта сборка работает без iCloud, поэтому присоединиться к семье в ней нельзя. В версии из App Store всё заработает 🙂",
                          systemImage: "icloud.slash").font(.subheadline).foregroundStyle(.secondary)
                } else if joined {
                    Label("Готово! Ты в семейном бюджете 🎉", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(Color.folkiAccent)
                } else {
                    row(1, "Попроси того, кто ведёт семейный бюджет, нажать «Пригласить» и отправить тебе ссылку.")
                    row(2, "Открой ссылку на этом iPhone — Folki сам подключит тебя к семье.")
                    row(3, "Свой личный бюджет ты настроишь дальше — его увидишь только ты 🤫")
                }
                Spacer()
            }
            .padding(FolkiSpacing.page)
            .navigationTitle("Меня пригласили").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Понятно") { dismiss() } } }
        }
    }

    private func row(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.headline).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(Color.folkiAccent, in: Circle())
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The icon's house: the walls stand still, and the two roof stripes fill in like the rings.
private struct AnimatedHouse: View {
    @State private var outer: CGFloat = 0
    @State private var inner: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let style = StrokeStyle(lineWidth: w * 0.13, lineCap: .round, lineJoin: .round)
            ZStack {
                Chevron(peak: 0.0, spread: 0.47, drop: 0.35).stroke(Color(red: 0.93, green: 0.58, blue: 0.16).opacity(0.16), style: style)
                Chevron(peak: 0.0, spread: 0.47, drop: 0.35).trim(from: 0, to: outer)
                    .stroke(Color(red: 0.93, green: 0.58, blue: 0.16), style: style)
                Chevron(peak: 0.19, spread: 0.30, drop: 0.215).stroke(Color(red: 0.10, green: 0.56, blue: 0.40).opacity(0.16), style: style)
                Chevron(peak: 0.19, spread: 0.30, drop: 0.215).trim(from: 0, to: inner)
                    .stroke(Color(red: 0.10, green: 0.56, blue: 0.40), style: style)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: w * 0.08, style: .continuous)
                        .fill(scheme == .dark ? Color(red: 0.96, green: 0.93, blue: 0.89) : Color(red: 0.09, green: 0.29, blue: 0.23))
                    UnevenRoundedRectangle(topLeadingRadius: w * 0.07, topTrailingRadius: w * 0.07)
                        .frame(width: w * 0.14, height: h * 0.27)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(width: w * 0.6, height: h * 0.4)
                .position(x: w / 2, y: h * 0.8)
            }
        }
        .onAppear(perform: play)
        .accessibilityHidden(true)
    }

    private func play() {
        guard !reduceMotion else { outer = 1; inner = 1; return }
        withAnimation(.easeInOut(duration: 0.9).delay(0.2)) { outer = 1 }
        withAnimation(.easeInOut(duration: 0.8).delay(0.55)) { inner = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { FolkiFeedback.tap() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) { FolkiFeedback.tap() }
    }
}

/// A roof stripe: peak at a fraction of the height, arms reaching `spread` of the width each side.
private struct Chevron: Shape {
    let peak: CGFloat
    let spread: CGFloat
    let drop: CGFloat
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.07
        let top = rect.minY + rect.height * peak + inset
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - rect.width * spread + inset, y: top + rect.height * drop))
        path.addLine(to: CGPoint(x: rect.midX, y: top))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * spread - inset, y: top + rect.height * drop))
        return path
    }
}

/// Static rings for the last page; they fill once on appear.
private struct DemoRings: View {
    let outer: Double
    let inner: Double
    @State private var shown = false
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * 0.11
            ZStack {
                ring(outer, palette: .personal, width: width)
                ring(inner, palette: .family, width: width).padding(width * 1.2)
            }
        }
        .onAppear { withAnimation(.spring(duration: 1, bounce: 0.15).delay(0.2)) { shown = true } }
        .accessibilityHidden(true)
    }
    private func ring(_ value: Double, palette: RingPalette, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(palette.start.opacity(0.16), lineWidth: width)
            Circle().trim(from: 0, to: shown ? value : 0)
                .stroke(palette.start, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }.padding(width / 2)
    }
}
