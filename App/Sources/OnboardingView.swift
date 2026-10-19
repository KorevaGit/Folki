import SwiftUI
import FolkiDuoCore

/// First launch: what the rings mean, the two budgets, the personal plan, then the family.
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
            TabView(selection: $page) {
                welcome.tag(0)
                budgets.tag(1)
                setup.tag(2)
                familyPage.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(reduceMotion ? nil : .smooth, value: page)
            dots.padding(.bottom, 16)
            footer.padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
        }
        .background { FolkiBackground() }
        .sheet(isPresented: $showingFamily) { SharingView(session: family) }
        .onChange(of: page) { FolkiFeedback.selection(); focused = page == 2 ? .available : nil }
    }

    // MARK: Pages

    private var welcome: some View {
        page(title: "Сколько можно\nпотратить сегодня",
             text: "Folki делит месячный план на дни. Кольцо показывает, сколько осталось на сегодня, и пересчитывает остальные дни после каждой траты.") {
            DemoRings(outer: 0.7, inner: 0.45).frame(width: 200, height: 200)
        }
    }

    private var budgets: some View {
        page(title: "Два бюджета",
             text: "Личный видишь только ты. Семейный общий для всех участников. Деньги из личного в семейный переводятся взносом — это не трата.") {
            HStack(spacing: 14) {
                budgetBadge("Личный", symbol: "person.fill", scope: .personal, note: "только ты")
                budgetBadge("Семейный", symbol: "person.2.fill", scope: .family, note: "вся семья")
            }
        }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Твой личный план").font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Две цифры — и Folki посчитает, сколько можно тратить в день. Всё можно поменять позже.")
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                amountField("Сколько денег у тебя сейчас", hint: "Всё, что есть на картах и наличными",
                            text: $available, field: .available)
                amountField("Сколько готов потратить за месяц", hint: "Без крупных обязательных платежей, если они уже отложены",
                            text: $monthly, field: .monthly)
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }.padding(.horizontal, FolkiSpacing.page).padding(.top, 48)
        }.scrollDismissesKeyboard(.interactively)
    }

    private var familyPage: some View {
        page(title: "Позови семью",
             text: "Пригласи до четырёх человек в семейный бюджет. Каждый увидит общие траты и взносы, а личные бюджеты останутся у каждого свои.") {
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

    private func budgetBadge(_ title: String, symbol: String, scope: BudgetScope, note: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Color.budget(scope))
                .frame(width: 76, height: 76).background(Color.budget(scope).opacity(0.14), in: Circle())
            Text(title).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 20).budgetCard()
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
            ForEach(0..<4) { index in
                Capsule().fill(index == page ? Color.folkiAccent : Color.secondary.opacity(0.3))
                    .frame(width: index == page ? 22 : 8, height: 8)
            }
        }.animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: page).accessibilityHidden(true)
    }

    @ViewBuilder private var footer: some View {
        switch page {
        case 2:
            Button(personal.result == nil ? "Создать план" : "Дальше") { createPlan() }
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                .disabled(personal.result == nil && plan == nil)
            Button("Сделаю позже") { page = 3 }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
        case 3:
            Button("Пригласить", systemImage: "person.badge.plus") { showingFamily = true }
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            Button("Начать без семьи") { finish() }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
        default:
            Button("Дальше") { page += 1 }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            Button("Пропустить") { finish() }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    private func createPlan() {
        guard personal.result == nil else { page = 3; return }
        guard let (monthlyPlan, funds) = plan else { return }
        do {
            try personal.createPlan(monthlyPlan: monthlyPlan, available: funds, reserves: [])
            FolkiFeedback.saved(); errorMessage = nil; focused = nil; page = 3
        } catch {
            errorMessage = "Не удалось сохранить план. Проверь суммы и попробуй снова."
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
