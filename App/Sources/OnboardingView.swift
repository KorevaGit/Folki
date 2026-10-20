import SwiftUI
import FolkiDuoCore

/// First launch, step by step: invite the family (or later), set the personal plan, then a short "how it works".
struct OnboardingView: View {
    let personal: BudgetSession
    let family: BudgetSession
    let finish: () -> Void
    @State private var page = 0
    @State private var monthly = ""
    @State private var available = ""
    @State private var errorMessage: String?
    @State private var showingFamily = false
    @FocusState private var focused: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field { case available, monthly }

    private var plan: (Money, Money)? {
        guard let plan = try? MoneyText.parse(monthly), plan.minorUnits > 0,
              let funds = try? MoneyText.parse(available), funds.minorUnits >= 0 else { return nil }
        return (plan, funds)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Шаг \(page + 1) из 3").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .contentTransition(.numericText()).padding(.top, 16)
            dots.padding(.top, 10)
            // Steps move forward only by the buttons, so nothing gets skipped by a stray swipe.
            ZStack {
                switch page {
                case 0: familyPage.transition(step)
                case 1: setup.transition(step)
                default: welcome.transition(step)
                }
            }.frame(maxHeight: .infinity)
            footer.padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
        }
        .background { FolkiBackground() }
        .sheet(isPresented: $showingFamily, onDismiss: { if family.members.filter(\.isActive).count > 1 { go(1) } }) {
            SharingView(session: family)
        }
        .onChange(of: page) { focused = page == 1 ? .available : nil }
    }

    private var step: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                              removal: .move(edge: .leading).combined(with: .opacity))
    }
    private func go(_ next: Int) {
        FolkiFeedback.selection()
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.15)) { page = next }
    }

    // MARK: Pages

    private var welcome: some View {
        page(title: String(localized: "Всё готово 🎉"),
             text: String(localized: "Кольцо покажет, сколько можно потратить сегодня: снаружи твой день, внутри семейный. Тратишь — кольцо тает 🍩")) {
            DemoRings(outer: 0.7, inner: 0.45).frame(width: 200, height: 200)
        }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Твой личный план").font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Две цифры — и Folki посчитает твой день ✨ Всё можно поменять потом.")
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                amountField(String(localized: "Сколько денег у тебя сейчас"), hint: String(localized: "Всё, что есть на картах и наличными"),
                            text: $available, field: .available)
                amountField(String(localized: "Сколько готов потратить за месяц"), hint: String(localized: "Без крупных обязательных платежей, если они уже отложены"),
                            text: $monthly, field: .monthly)
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }.padding(.horizontal, FolkiSpacing.page).padding(.top, 24)
        }.scrollDismissesKeyboard(.interactively)
    }

    private var familyPage: some View {
        page(title: String(localized: "Начнём с семьи"),
             text: String(localized: "Ты можешь позвать до 4 близких 🏡 Общие траты будут видны всем, а личный бюджет у каждого свой.")) {
            Image(systemName: "person.2.circle.fill").font(.system(size: 120))
                .foregroundStyle(Color.budget(.family), Color.budget(.family).opacity(0.2))
        }
    }

    // MARK: Parts

    private func page<Art: View>(title: String, text: String, @ViewBuilder art: () -> Art) -> some View {
        VStack(spacing: 28) {
            Spacer(minLength: 20)
            art()
            VStack(spacing: 12) {
                Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold)).multilineTextAlignment(.center)
                Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
        }.padding(.horizontal, 28)
    }

    private func amountField(_ title: String, hint: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("0", text: text).keyboardType(.decimalPad).focused($focused, equals: field)
                    .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text(MoneyText.symbol).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                Capsule().fill(index == page ? Color.folkiAccent : Color.secondary.opacity(0.3))
                    .frame(width: index == page ? 22 : 8, height: 8)
            }
        }.animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: page).accessibilityHidden(true)
    }

    @ViewBuilder private var footer: some View {
        switch page {
        case 0:
            Button("Пригласить", systemImage: "person.badge.plus") { FolkiFeedback.tap(); showingFamily = true }
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            Button("Добавлю позже") { go(1) }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
        case 1:
            Button(personal.result == nil ? String(localized: "Создать план") : String(localized: "Дальше")) { createPlan() }
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                .disabled(personal.result == nil && plan == nil)
            Button("Сделаю позже") { go(2) }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
        default:
            Button("Начать") { FolkiFeedback.success(); finish() }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        }
    }

    private func createPlan() {
        guard personal.result == nil else { go(2); return }
        guard let (monthlyPlan, funds) = plan else { return }
        do {
            try personal.createPlan(monthlyPlan: monthlyPlan, available: funds, reserves: [])
            FolkiFeedback.saved(); errorMessage = nil; focused = nil; go(2)
        } catch {
            errorMessage = String(localized: "Не получилось сохранить план. Проверь суммы и попробуй снова.")
        }
    }
}

/// Static rings for the welcome page; they fill once on appear.
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
