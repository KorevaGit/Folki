import SwiftUI
import FolkiDuoCore

/// A current balance and the next payday are enough to start. Salary planning is optional.
struct OnboardingView: View {
    let personal: BudgetSession
    let family: BudgetSession
    let finish: () -> Void
    @AppStorage("FolkiOnboardingStep") private var page = 0
    @AppStorage("FolkiOnboardingAvailable") private var available = ""
    @AppStorage("FolkiOnboardingPayday") private var paydayTimestamp = 0.0
    @State private var forward = true
    @State private var editingAmount = false
    @State private var showingFamily = false
    @State private var showingJoin = false
    @State private var showingPlan = false
    @State private var errorMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var payday: Binding<Date> {
        Binding(get: { paydayTimestamp > 0 ? Date(timeIntervalSince1970: paydayTimestamp) : defaultPayday },
                set: { paydayTimestamp = $0.timeIntervalSince1970 })
    }
    private var minimumPayday: Date {
        personal.calendar.date(byAdding: .day, value: 1, to: personal.calendar.startOfDay(for: personal.referenceDate))!
    }
    private var defaultPayday: Date { personal.calendar.date(byAdding: .month, value: 1, to: personal.referenceDate) ?? minimumPayday }
    private var funds: Money? { (try? MoneyText.parse(available)).flatMap { $0.minorUnits > 0 ? $0 : nil } }
    private var estimate: DailyBudgetSnapshot? {
        guard let funds, let period = try? BudgetPeriod.untilPayday(from: personal.referenceDate, payday: payday.wrappedValue,
                timeZoneIdentifier: personal.calendar.timeZone.identifier) else { return nil }
        return try? DailyBudgetCalculator.calculate(HouseholdSnapshot(period: period, monthlyFreePlan: funds, openingFunds: funds), asOf: personal.referenceDate)
    }
    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 56).padding(.top, 12).padding(.horizontal, FolkiSpacing.page)
            ZStack {
                switch page {
                case 0: intro.transition(step)
                case 1: familyPage.transition(step)
                case 2: moneyPage.transition(step)
                case 3: planPage.transition(step)
                default: readyPage.transition(step)
                }
            }.frame(maxHeight: .infinity)
            VStack(spacing: 12) {
                if editingAmount {
                    AmountKeypad(text: $available)
                    Button("Готово") { withAnimation(.snappy) { editingAmount = false } }
                        .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                } else { footer }
            }.padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
        }
        .background { FolkiBackground() }
        .environment(\.calendar, personal.calendar).environment(\.timeZone, personal.calendar.timeZone)
        .sheet(isPresented: $showingJoin) { JoinFamilyView(family: family).presentationDetents([.medium]) }
        .sheet(isPresented: $showingFamily) { SharingView(session: family) }
        .sheet(isPresented: $showingPlan) { BudgetSetupView(session: personal, editingCurrent: true) }
        .onChange(of: page) { editingAmount = false; errorMessage = nil }
        .onAppear {
            if page == 3 && personal.result == nil { page = 2 }
            if payday.wrappedValue < minimumPayday { paydayTimestamp = defaultPayday.timeIntervalSince1970 }
        }
    }
    private var step: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
    private func go(_ next: Int) {
        FolkiFeedback.selection(); forward = next > page
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.15)) { page = next }
    }
    private var header: some View {
        ZStack {
            if page > 0 {
                VStack(spacing: 8) {
                    Text("Шаг \(min(page, 4)) из 4").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(1...4, id: \.self) { i in
                            Capsule().fill(i <= page ? Color.folkiAccent : Color.folkiInk.opacity(0.12)).frame(width: i == page ? 24 : 8, height: 8)
                        }
                    }.accessibilityHidden(true)
                }
                HStack {
                    Button { go(page - 1) } label: { Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44) }
                        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Назад")
                    Spacer()
                }
            }
        }
    }
    private var intro: some View {
        illustration(title: "Привет! Это Folki 👋", text: "Бюджет, в котором сразу видно, сколько можно потратить сегодня.") {
            AnimatedHouse().frame(width: 210, height: 190)
        }
    }
    private var familyPage: some View {
        VStack(spacing: 12) {
            illustration(title: "Начнём с семьи", text: "Ты можешь позвать до 4 близких 🏡 Общие траты будут видны всем, а личный бюджет у каждого свой.") {
                FamilyBubbles(family: family) { FolkiFeedback.tap(); showingFamily = true }.frame(height: 240)
            }
            Button("Меня пригласили 💌") { showingJoin = true }.buttonStyle(FolkiSoftButtonStyle()).padding(.horizontal, 28)
        }
    }
    private var moneyPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Деньги до зарплаты").font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Две вещи — и Folki сразу разложит деньги по дням ✨").foregroundStyle(.secondary)
                if personal.result != nil {
                    Text("Период уже создан: \(personal.periodTitle)").font(.headline)
                    Text("Платежи и копилку можно настроить на следующем шаге.").foregroundStyle(.secondary)
                } else {
                    Text("Сколько денег есть сейчас").font(.headline)
                    Button { withAnimation(.snappy) { editingAmount = true } } label: {
                        HStack {
                            Text(available.isEmpty ? "0" : available).monospacedDigit()
                            Text(MoneyText.symbol).foregroundStyle(.secondary)
                            Spacer()
                        }.font(.system(size: 34, weight: .bold, design: .rounded)).padding(18)
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain)
                    DatePicker("Следующая зарплата", selection: payday, in: minimumPayday..., displayedComponents: .date)
                    if let estimate {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Сегодня можно").font(.subheadline).foregroundStyle(.secondary)
                            Text(MoneyText.whole(estimate.todayGuide)).font(.system(.largeTitle, design: .rounded, weight: .bold))
                            Text("До зарплаты \(estimate.remainingDays) дн. Дата зарплаты начнёт следующий период.").font(.footnote).foregroundStyle(.secondary)
                        }.budgetCard()
                    }
                }
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }.folkiPagePadding()
        }
    }
    private var planPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("План уже работает 🎉").font(.system(.largeTitle, design: .rounded, weight: .bold))
                if let result = personal.result {
                    Text("Сегодня можно \(MoneyText.whole(result.todayRemaining))").font(.title2.bold())
                    Text(personal.periodTitle).foregroundStyle(.secondary)
                }
                Text("Хочешь отложить на аренду, подписки или в копилку? Составь план по зарплате. Платежи будут отдельно от повседневных денег.")
                    .foregroundStyle(.secondary)
                Button("Составить план по зарплате") { showingPlan = true }.buttonStyle(FolkiSoftButtonStyle())
                Text("Можно сделать позже в настройках.").font(.footnote).foregroundStyle(.secondary)
            }.folkiPagePadding()
        }
    }
    private var readyPage: some View {
        illustration(title: "Всё готово 🎉", text: "Кольца покажут остаток: снаружи личный бюджет, внутри семейный. Нажми на кольца, чтобы переключить день и весь период до зарплаты 🍩") {
            DemoRings(outer: 0.7, inner: 0.45).frame(width: 200, height: 200)
        }
    }
    private func illustration<Art: View>(title: LocalizedStringKey, text: LocalizedStringKey, @ViewBuilder art: () -> Art) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                art()
                Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(text).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).padding(28).frame(maxWidth: .infinity)
        }.scrollBounceBehavior(.basedOnSize)
    }
    @ViewBuilder private var footer: some View {
        switch page {
        case 0:
            Button("Поехали") { go(1) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        case 1:
            Button("Дальше") { go(2) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            Button("Пригласить близких") { showingFamily = true }.font(.subheadline).foregroundStyle(.secondary)
        case 2:
            Button(personal.result == nil ? "Начать период" : "Дальше", action: createPeriod)
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(personal.result == nil && estimate == nil)
        case 3:
            Button("Дальше") { go(4) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        default:
            Button("Начать") { FolkiFeedback.success(); available = ""; paydayTimestamp = 0; finish() }
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        }
    }
    private func createPeriod() {
        if personal.result != nil { go(3); return }
        guard let funds else { return }
        do {
            try personal.createPlan(monthlyPlan: funds, available: funds, payday: payday.wrappedValue)
            FolkiFeedback.saved(); go(3)
        } catch { errorMessage = String(localized: "Не получилось сохранить. Проверь сумму, дату и попробуй снова.") }
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
