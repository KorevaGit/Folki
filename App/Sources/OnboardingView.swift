import SwiftUI
import FolkiDuoCore

/// First launch: hello, then four steps — family (or later), how much to save, the category split, how the rings work.
/// The step is stored, so a relaunch (for example after changing the app language) continues where it stopped.
struct OnboardingView: View {
    let personal: BudgetSession
    let family: BudgetSession
    let finish: () -> Void
    @AppStorage("FolkiOnboardingStep") private var page = 0
    @State private var forward = true
    @State private var available = ""
    @State private var saving = ""
    @State private var split: [UUID: String] = [:]
    @State private var errorMessage: String?
    @State private var showingFamily = false
    /// The amount the keypad is typing into; nil hides the keypad.
    @State private var active: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field: Hashable { case available, saving, category(UUID) }
    private let steps = 4

    private var funds: Money? { (try? MoneyText.parse(available)).flatMap { $0.minorUnits > 0 ? $0 : nil } }
    private var savingAmount: Money { (try? MoneyText.parse(saving)).flatMap { $0.minorUnits >= 0 ? $0 : nil } ?? Money(minorUnits: 0) }
    /// What is left to spend once the saving is set aside.
    private var spendable: Money? {
        guard let funds, savingAmount.minorUnits < funds.minorUnits else { return nil }
        return Money(minorUnits: funds.minorUnits - savingAmount.minorUnits)
    }
    private var splitTotal: Money {
        Money(minorUnits: split.values.reduce(0) { $0 + ((try? MoneyText.parse($1))?.minorUnits ?? 0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 56).padding(.top, 12).padding(.horizontal, FolkiSpacing.page)
            // Steps move only by the buttons, so nothing gets skipped by a stray swipe.
            ZStack {
                switch page {
                case 0: intro.transition(step)
                case 1: familyPage.transition(step)
                case 2: savingPage.transition(step)
                case 3: splitPage.transition(step)
                default: readyPage.transition(step)
                }
            }.frame(maxHeight: .infinity)
            Group {
                if let active {
                    // The same keypad as on the spend screen, instead of the system keyboard.
                    VStack(spacing: 12) {
                        AmountKeypad(text: binding(for: active))
                        if active == .available {
                            Button("Дальше") { choose(.saving) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                        } else {
                            Button("Готово") { withAnimation(.snappy) { self.active = nil } }
                                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                        }
                    }.transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    VStack(spacing: 0) { footer }.transition(.opacity)
                }
            }
            .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: active == nil)
        }
        .background { FolkiBackground() }
        .sheet(isPresented: $showingFamily, onDismiss: { if family.members.filter(\.isActive).count > 1 { FolkiFeedback.success() } }) {
            SharingView(session: family)
        }
        .onChange(of: page) { active = page == 2 ? .available : nil }
    }

    // MARK: Navigation

    private var step: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
    private func go(_ next: Int) {
        FolkiFeedback.selection()
        forward = next > page
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.15)) { page = next }
    }

    private var header: some View {
        ZStack {
            if page > 0 {
                VStack(spacing: 10) {
                    Text("Шаг \(page) из \(steps)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    dots
                }
                HStack {
                    Button { go(page - 1) } label: {
                        Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Назад")
                    Spacer()
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: page > 0)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(1...steps, id: \.self) { index in
                Capsule().fill(index == page ? Color.folkiAccent : Color.secondary.opacity(0.3))
                    .frame(width: index == page ? 22 : 8, height: 8)
            }
        }.animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: page).accessibilityHidden(true)
    }

    // MARK: Pages

    private var intro: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 20)
            AnimatedHouse().frame(width: 210, height: 190)
            VStack(spacing: 12) {
                Text("Привет! Это Folki 👋").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Семейный бюджет, в котором сразу видно, сколько можно потратить сегодня.")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }.folkiAppear(8)
            Spacer(minLength: 20)
        }.padding(.horizontal, 28)
    }

    private var familyPage: some View {
        page(title: String(localized: "Начнём с семьи"),
             text: String(localized: "Ты можешь позвать до 4 близких 🏡 Общие траты будут видны всем, а личный бюджет у каждого свой.")) {
            FamilyBubbles(family: family) { FolkiFeedback.tap(); showingFamily = true }
                .frame(height: 290)
        }
    }

    private var savingPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Сначала — копилка").font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Скажи, сколько хочешь отложить, а остальное Folki сам разложит по тратам ✨")
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                amountField(String(localized: "Сколько денег у тебя сейчас"), hint: String(localized: "Всё, что есть на картах и наличными"),
                            text: $available, field: .available)
                amountField(String(localized: "Сколько хочешь отложить в этом месяце"), hint: String(localized: "Эти деньги не попадут в траты на день 🐷"),
                            text: $saving, field: .saving)
                if let spendable {
                    HStack {
                        Text("На жизнь останется").foregroundStyle(.secondary)
                        Spacer()
                        Text(MoneyText.whole(spendable)).font(.headline).monospacedDigit()
                            .contentTransition(.numericText()).animation(.snappy, value: spendable.minorUnits)
                    }.budgetCard()
                } else if funds != nil {
                    Text("Отложить можно меньше, чем есть сейчас 🙂").font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, FolkiSpacing.page).padding(.top, 12)
        }.scrollDismissesKeyboard(.interactively)
    }

    private var splitPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Твой план на месяц").font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Разложили по обычным долям. Поправь любую сумму, если у тебя по-другому.")
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Label("Копилка", systemImage: "banknote.fill").foregroundStyle(Color.folkiAccent)
                    Spacer()
                    moneyInput($saving, field: .saving)
                }.font(.headline).budgetCard()
                VStack(spacing: 0) {
                    ForEach(BuiltInCategory.allCases, id: \.self) { builtIn in
                        let category = builtIn.category
                        HStack(spacing: 12) {
                            CategoryIcon(category: category, size: 30)
                            Text(category.name).font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 8)
                            moneyInput(Binding(get: { split[builtIn.id] ?? "" }, set: { split[builtIn.id] = $0 }),
                                       field: .category(builtIn.id))
                        }.padding(.vertical, 8)
                        if builtIn != BuiltInCategory.allCases.last { Divider().padding(.leading, 42) }
                    }
                }.budgetCard()
                totals
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }.padding(.horizontal, FolkiSpacing.page).padding(.top, 12).padding(.bottom, 16)
        }.scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var totals: some View {
        let total = splitTotal.minorUnits + savingAmount.minorUnits
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Траты за месяц").foregroundStyle(.secondary)
                Spacer()
                Text(MoneyText.whole(splitTotal)).font(.headline).monospacedDigit()
            }
            if let funds {
                let left = funds.minorUnits - total
                Text(left >= 0 ? String(localized: "Не распределено: \(MoneyText.whole(Money(minorUnits: left)))")
                               : String(localized: "Больше, чем есть, на \(MoneyText.whole(Money(minorUnits: -left))) — поправь суммы 🙏"))
                    .font(.footnote).foregroundStyle(left >= 0 ? Color.secondary : Color.red)
            }
        }.padding(.horizontal, 4)
    }

    private var readyPage: some View {
        page(title: String(localized: "Всё готово 🎉"),
             text: String(localized: "Кольцо покажет, сколько можно потратить сегодня: снаружи твой день, внутри семейный. Тратишь — кольцо тает 🍩")) {
            DemoRings(outer: 0.7, inner: 0.45).frame(width: 200, height: 200)
        }
    }

    // MARK: Parts

    private func page<Art: View>(title: String, text: String, @ViewBuilder art: () -> Art) -> some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)
            art()
            VStack(spacing: 12) {
                Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold)).multilineTextAlignment(.center)
                Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
        }.padding(.horizontal, 28)
    }

    private func binding(for field: Field) -> Binding<String> {
        switch field {
        case .available: $available
        case .saving: $saving
        case .category(let id): Binding(get: { split[id] ?? "" }, set: { split[id] = $0 })
        }
    }

    private func choose(_ field: Field) {
        FolkiFeedback.selection()
        withAnimation(.snappy) { active = field }
    }

    private func amountField(_ title: String, hint: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Button { choose(field) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(text.wrappedValue.isEmpty ? "0" : text.wrappedValue)
                        .foregroundStyle(text.wrappedValue.isEmpty ? .tertiary : .primary)
                        .contentTransition(.numericText()).animation(.snappy, value: text.wrappedValue)
                    Text(MoneyText.symbol).foregroundStyle(.tertiary)
                    Spacer()
                }
                .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                .padding(.horizontal, 18).padding(.vertical, 12)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.folkiAccent, lineWidth: active == field ? 2 : 0)
                }
            }.buttonStyle(.plain)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func moneyInput(_ text: Binding<String>, field: Field) -> some View {
        Button { choose(field) } label: {
            HStack(spacing: 4) {
                Text(text.wrappedValue.isEmpty ? "0" : text.wrappedValue).monospacedDigit()
                    .contentTransition(.numericText()).animation(.snappy, value: text.wrappedValue)
                Text(MoneyText.symbol).foregroundStyle(.secondary)
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(active == field ? Color.folkiAccent.opacity(0.18) : Color.folkiSoft, in: Capsule())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var footer: some View {
        switch page {
        case 0:
            Button("Поехали") { go(1) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            // Keeps the footer the same height on every page.
            Text(" ").font(.subheadline).padding(.top, 8).accessibilityHidden(true)
        case 1:
            if family.members.filter(\.isActive).count > 1 {
                Button("Дальше") { go(2) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            } else {
                Button("Пригласить", systemImage: "person.badge.plus") { FolkiFeedback.tap(); showingFamily = true }
                    .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            }
            Button("Добавлю позже") { go(2) }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
        case 2:
            if personal.result == nil {
                Button("Разложить по тратам") { fillSplit(); go(3) }
                    .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(spendable == nil)
            } else {
                Button("Дальше") { go(4) }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            }
            Button("Сделаю позже") { go(4) }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
        case 3:
            Button("Создать план") { createPlan() }
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(splitTotal.minorUnits <= 0)
            Button("Сделаю позже") { go(4) }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
        default:
            Button("Начать") { FolkiFeedback.success(); finish() }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            Text(" ").font(.subheadline).padding(.top, 8).accessibilityHidden(true)
        }
    }

    /// Splits what is left to spend by the usual shares, rounded to 100 ₽; the remainder goes to «Другое».
    private func fillSplit() {
        guard let spendable else { return }
        var amounts: [UUID: Int64] = [:]
        for builtIn in BuiltInCategory.allCases where builtIn != .other {
            amounts[builtIn.id] = Int64(Double(spendable.minorUnits) * CategoryGuide.share(of: builtIn)) / 10_000 * 10_000
        }
        amounts[BuiltInCategory.other.id] = spendable.minorUnits - amounts.values.reduce(0, +)
        split = amounts.mapValues { MoneyText.input(Money(minorUnits: $0)).replacingOccurrences(of: ".", with: ",") }
    }

    private func createPlan() {
        guard let funds, splitTotal.minorUnits > 0 else { return }
        guard splitTotal.minorUnits + savingAmount.minorUnits <= funds.minorUnits else {
            errorMessage = String(localized: "Траты и копилка больше, чем есть сейчас. Поправь суммы 🙏")
            return
        }
        let reserves = savingAmount.minorUnits > 0 ? [ProtectedReserve(name: String(localized: "Копилка"), openingAmount: savingAmount)] : []
        do {
            try personal.createPlan(monthlyPlan: splitTotal, available: funds, reserves: reserves)
            CategoryPlanStore.save(split.compactMapValues { try? MoneyText.parse($0) }.filter { $0.value.minorUnits > 0 }, scope: .personal)
            FolkiFeedback.saved(); errorMessage = nil; active = nil; go(4)
        } catch {
            errorMessage = String(localized: "Не получилось сохранить план. Проверь суммы и попробуй снова.")
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
