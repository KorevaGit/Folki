import SwiftUI
import FolkiDuoCore

func distributionTitle(_ day: Int) -> String {
    day == 0 ? String(localized: "До конца месяца") : String(localized: "По \(day)-е число")
}

struct DistributionChoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var day: Int
    var apply: ((Int) throws -> Void)? = nil
    @State private var selection = 0
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Picker("Распределять деньги", selection: $selection) {
                    Text("До конца месяца").tag(0)
                    ForEach(1...31, id: \.self) { Text("По \($0)-е число").tag($0) }
                }.pickerStyle(.wheel)
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }.folkiFormLayout().navigationTitle("Распределение").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            do { try apply?(selection); day = selection; dismiss() }
                            catch { errorMessage = String(localized: "Не получилось изменить срок. Попробуй ещё раз.") }
                        }
                    }
                }.onAppear { selection = day }
        }.presentationDetents([.medium])
    }
}

/// "Внести": the amount first, then where it goes — family share, envelopes, the rest to live on.
struct DailyFundingView: View {
    let personal: BudgetSession
    let family: BudgetSession
    var initialScope: BudgetScope = .personal
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum FamilySource: Hashable { case contribution, income }
    @State private var scope: BudgetScope = .personal
    @State private var source: FamilySource = .contribution
    @State private var amount = ""
    @State private var splitting = false
    @State private var shareToFamily = true
    @State private var split = EnvelopeDistribution(incoming: Money(minorUnits: 0), fills: [:])
    @State private var operationID = UUID()
    @State private var errorMessage: String?

    private var hasFamily: Bool { family.household != nil }
    private var session: BudgetSession { scope == .personal ? personal : family }
    private var money: Money? { (try? MoneyText.parse(amount)).flatMap { $0.minorUnits > 0 ? $0 : nil } }
    private var isContribution: Bool { scope == .family && source == .contribution }
    /// "В семью 30% · X ₽", raised by family envelopes due within a week.
    private var familyShare: Money {
        guard scope == .personal, hasFamily, shareToFamily, let money else { return Money(minorUnits: 0) }
        return (try? ContributionAdvisor.suggestion(topUp: money, percent: family.contributionPercent,
                                                     urgentFamilyShortfalls: family.urgentShortfalls)) ?? Money(minorUnits: 0)
    }
    private var envelopeBase: Money {
        guard let money, !isContribution else { return Money(minorUnits: 0) }
        return (try? money.subtracting(familyShare)) ?? money
    }
    /// The envelopes that can take money now: due this period and still short.
    private var openEnvelopes: [RecurringEnvelope] {
        session.envelopes.filter { ((try? $0.shortfall(balance: session.envelopeBalance($0)).minorUnits) ?? 0) > 0 }
    }
    private var needsSplit: Bool {
        !isContribution && (!openEnvelopes.isEmpty || (scope == .personal && hasFamily))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: FolkiSpacing.page) {
                if hasFamily {
                    FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: $scope,
                        options: [(String(localized: "Личный"), BudgetScope.personal), (String(localized: "Семья"), BudgetScope.family)],
                        minimumHeight: 40)
                }
                if splitting { splitPage.transition(.move(edge: .trailing).combined(with: .opacity)) }
                else { amountPage.transition(.move(edge: .leading).combined(with: .opacity)) }
            }
            .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.xs)
            .background { FolkiBackground() }
            .navigationTitle("Внести").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if splitting {
                        Button("Назад", systemImage: "chevron.left") { move { splitting = false } }
                    } else {
                        Button("Отмена") { dismiss() }
                    }
                }
            }
            .onAppear { scope = hasFamily ? initialScope : .personal }
            .onChange(of: scope) { operationID = UUID(); errorMessage = nil; move { splitting = false } }
            .onChange(of: shareToFamily) { split = session.distribution(of: envelopeBase) }
        }
    }

    private var amountView: some View {
        Text("\(amount.isEmpty ? "0" : MoneyText.grouped(amount)) ₽")
            .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(money == nil ? .tertiary : .primary)
            .lineLimit(1).minimumScaleFactor(0.4).fixedSize(horizontal: false, vertical: true)
            .contentTransition(.numericText()).animation(FolkiMotion.quick, value: amount)
    }

    private var amountPage: some View {
        VStack(spacing: FolkiSpacing.page) {
            amountView.padding(.top, FolkiSpacing.page)
            if scope == .family { familySources }
            if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            Spacer(minLength: 0)
            AmountKeypad(text: $amount)
            Button(needsSplit ? String(localized: "Дальше") : String(localized: "Внести")) {
                guard money != nil else { FolkiFeedback.boundary(); return }
                if needsSplit {
                    split = session.distribution(of: envelopeBase)
                    move { splitting = true }
                } else { save() }
            }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        }
    }

    private var familySources: some View {
        VStack(spacing: 0) {
            radio(.contribution, "Из моего личного", "Это вклад: в личном станет меньше")
            Divider().padding(.leading, 44)
            radio(.income, "Общие поступления", "Деньги пришли сразу в семью")
        }
        .padding(.horizontal, FolkiSpacing.card)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
    }

    private func radio(_ value: FamilySource, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        Button {
            FolkiFeedback.selection(); source = value; errorMessage = nil
        } label: {
            HStack(spacing: FolkiSpacing.item) {
                Image(systemName: source == value ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(source == value ? Color.folkiAccent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(Color.folkiInk)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.frame(minHeight: 60).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(source == value ? .isSelected : [])
    }

    private var splitPage: some View {
        VStack(spacing: FolkiSpacing.page) {
            Button { move { splitting = false } } label: { amountView }.buttonStyle(.plain)
                .accessibilityHint("Изменить сумму")
            ScrollView {
                VStack(spacing: FolkiSpacing.item) {
                    if scope == .personal && hasFamily { shareRow }
                    ForEach(openEnvelopes) { envelope in envelopeSlider(envelope) }
                }
            }.scrollBounceBehavior(.basedOnSize)
            livingRow
            if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            Button("Внести", action: save).buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        }
    }

    private var shareRow: some View {
        Toggle(isOn: $shareToFamily.animation(FolkiMotion.quick)) {
            HStack(spacing: FolkiSpacing.item) {
                Image(systemName: "heart.fill").foregroundStyle(RingPalette.family.start)
                    .frame(width: 36, height: 36).background(RingPalette.family.start.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("В семью \(family.contributionPercent)%").font(.body.weight(.medium))
                    Text(MoneyText.whole(shareToFamily ? familyShare : (money.flatMap { try? ContributionAdvisor.suggestion(topUp: $0,
                        percent: family.contributionPercent, urgentFamilyShortfalls: family.urgentShortfalls) } ?? Money(minorUnits: 0))))
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .tint(RingPalette.family.start)
        .padding(FolkiSpacing.card)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
    }

    private func envelopeSlider(_ envelope: RecurringEnvelope) -> some View {
        let balance = session.envelopeBalance(envelope)
        let need = (try? envelope.shortfall(balance: balance)) ?? envelope.size
        let fill = split.fills[envelope.id] ?? Money(minorUnits: 0)
        let urgency = session.envelopeUrgency(envelope)
        let binding = Binding<Double>(
            get: { Double(fill.minorUnits / 100) },
            set: { value in
                let rounded = Money(minorUnits: Int64(value.rounded()) * 100)
                if let next = try? EnvelopeDistributor.adjusting(split, envelope: envelope, balance: balance, to: rounded) {
                    // A tick only at the ends, not on every rouble.
                    let edge = next.fills[envelope.id] == nil || next.fills[envelope.id] == need
                    if edge && next.fills[envelope.id] != split.fills[envelope.id] { FolkiFeedback.selection() }
                    split = next
                }
            })
        return VStack(alignment: .leading, spacing: FolkiSpacing.xs) {
            HStack {
                Text(envelope.name).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                Text("\(MoneyText.whole(fill)) из \(MoneyText.whole(need.roundedUpToWholeUnits))")
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: binding, in: 0...max(1, Double(need.roundedUpToWholeUnits.minorUnits / 100)), step: 1)
                .tint(urgency == .calm || urgency == .funded ? Color.folkiAccent : urgency.color)
                .accessibilityLabel(envelope.name)
                .accessibilityValue(MoneyText.whole(fill))
            Text(dueLine(envelope)).font(.footnote).foregroundStyle(urgency == .calm ? .secondary : urgency.color)
        }
        .padding(FolkiSpacing.card)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
    }

    private func dueLine(_ envelope: RecurringEnvelope) -> String {
        let days = session.daysUntil(envelope)
        let date = envelope.nextDue.formatted(.dateTime.day().month(.abbreviated))
        return days <= 0 ? String(localized: "Оплата сегодня") : String(localized: "Оплата \(date) · через \(days) дн.")
    }

    private var living: Money {
        let envelopes = split.fills.values.reduce(Int64(0)) { $0 + $1.minorUnits }
        return Money(minorUnits: max(0, envelopeBase.minorUnits - envelopes))
    }

    private var livingRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("На жизнь").font(.headline)
            Spacer()
            Text(MoneyText.whole(living)).font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
                .foregroundStyle(Color.folkiAccent).contentTransition(.numericText()).animation(FolkiMotion.quick, value: living)
        }
    }

    private func move(_ change: () -> Void) {
        withAnimation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion), change)
    }

    private func save() {
        guard let money else { FolkiFeedback.boundary(); return }
        do {
            if isContribution {
                let free = personal.result?.monthlyRemaining.nonnegative ?? Money(minorUnits: 0)
                guard money.minorUnits <= free.minorUnits else {
                    errorMessage = String(localized: "В личном свободно только \(MoneyText.whole(free))")
                    FolkiFeedback.boundary(); return
                }
                try personal.contribute(money, to: family, linkID: operationID)
            } else {
                try session.addDailyFunds(money, operationID: operationID)
                let share = familyShare
                if share.minorUnits > 0 { try personal.contribute(share, to: family, linkID: UUID()) }
                for envelope in openEnvelopes {
                    if let fill = split.fills[envelope.id], fill.minorUnits > 0 { try session.fundEnvelope(envelope, amount: fill) }
                }
            }
            FolkiFeedback.saved()
            dismiss()
        } catch {
            errorMessage = String(localized: "Не получилось внести деньги. Попробуй ещё раз.")
        }
    }
}
