import SwiftUI
import FolkiDuoCore

func periodRuleTitle(_ rule: PeriodRule) -> String {
    switch rule {
    case .monthEnd: String(localized: "До конца месяца")
    case .dayOfMonth(let day): String(localized: "По \(day)-е число")
    case .days(7): String(localized: "Каждую неделю")
    case .days(let length): String(localized: "По \(length) дн.")
    }
}

/// How the period ends now and how it is extended later.
struct DistributionChoiceView: View {
    @Environment(\.dismiss) private var dismiss
    let current: PeriodRule
    let apply: (PeriodRule) throws -> Void
    @State private var selection: PeriodRule = .monthEnd
    @State private var errorMessage: String?
    private var choices: [PeriodRule] {
        var rules: [PeriodRule] = [.days(7), .monthEnd] + (1...31).map(PeriodRule.dayOfMonth)
        if !rules.contains(current) { rules.insert(current, at: 0) }
        return rules
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Распределять деньги", selection: $selection) {
                    ForEach(choices, id: \.self) { Text(periodRuleTitle($0)).tag($0) }
                }.pickerStyle(.wheel)
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }.folkiFormLayout().navigationTitle("Распределение").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { FolkiCloseButton { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            do { try apply(selection); dismiss() }
                            catch { errorMessage = String(localized: "Не получилось изменить срок. Попробуй ещё раз.") }
                        }
                    }
                }.onAppear { selection = current }
        }.presentationDetents([.medium])
    }
}

/// "Внести": the amount first, then where it goes — family share, envelopes, the rest to live on.
struct DailyFundingView: View {
    let personal: BudgetSession
    let family: BudgetSession
    var initialScope: BudgetScope = .personal
    var distributesExisting = false
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
    @State private var receipt: Receipt?
    @State private var isSaving = false
    private struct Line: Identifiable { let id: UUID; let name: String; let amount: Money }
    private struct Receipt {
        let amount: Money
        let living: Money
        let share: Money
        let lines: [Line]
        let before: DailyBudgetSnapshot?
        let after: DailyBudgetSnapshot?
    }

    private var hasFamily: Bool { family.household != nil }
    private var session: BudgetSession { scope == .personal ? personal : family }
    private var money: Money? { (try? MoneyText.parse(amount)).flatMap { $0.minorUnits > 0 ? $0 : nil } }
    private var isContribution: Bool { scope == .family && source == .contribution }
    /// "В семью 30% · X ₽", raised by family envelopes due within a week.
    private var familyShare: Money {
        guard !distributesExisting, scope == .personal, hasFamily, shareToFamily, let money else { return Money(minorUnits: 0) }
        return (try? ContributionAdvisor.suggestion(topUp: money, percent: family.contributionPercent,
                                                     urgentFamilyShortfalls: family.urgentShortfalls,
                                                     personalObligations: personal.mandatoryObligations)) ?? Money(minorUnits: 0)
    }
    private var envelopeBase: Money {
        guard let money, !isContribution else { return Money(minorUnits: 0) }
        return (try? money.subtracting(familyShare)) ?? money
    }
    /// The envelopes that can take money now: due this period and still short.
    private var openEnvelopes: [RecurringEnvelope] {
        session.envelopes.filter { ((try? $0.shortfall(balance: session.envelopeBalance($0)).minorUnits) ?? 0) > 0 }
    }
    private var projected: DailyBudgetSnapshot? {
        guard let money else { return nil }
        if distributesExisting { return session.previewAvailableDistribution(split.fills) }
        if isContribution { return family.previewTransfer(money, kind: .contributionIn) }
        return session.previewFunding(money, fills: split.fills, familyShare: familyShare)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: FolkiSpacing.page) {
                if hasFamily && receipt == nil && !distributesExisting {
                    FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: $scope,
                        options: [(String(localized: "Личный"), BudgetScope.personal), (String(localized: "Семья"), BudgetScope.family)],
                        minimumHeight: 40)
                }
                if let receipt { receiptPage(receipt) }
                else if splitting { splitPage.transition(.move(edge: .trailing).combined(with: .opacity)) }
                else { amountPage.transition(.move(edge: .leading).combined(with: .opacity)) }
            }
            .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.xs)
            .background { FolkiBackground() }
            .navigationTitle(distributesExisting ? "Распределить бюджет" : "Внести").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if receipt != nil {
                        Button("Готово") { dismiss() }
                    } else if splitting && !distributesExisting {
                        Button("Назад", systemImage: "chevron.left") { move { splitting = false } }
                    } else {
                        FolkiCloseButton { dismiss() }
                    }
                }
            }
            .onAppear {
                scope = hasFamily ? initialScope : .personal
                do { try session.ensureDailyPeriod() } catch { errorMessage = String(localized: "Не получилось открыть бюджет") }
                if distributesExisting {
                    amount = MoneyText.input(session.availableForDailySpending)
                    splitting = true
                    updateSplit()
                }
            }
            .onChange(of: scope) {
                operationID = UUID(); errorMessage = nil; move { splitting = distributesExisting }
                do { try session.ensureDailyPeriod() } catch { errorMessage = String(localized: "Не получилось открыть бюджет") }
                if distributesExisting { amount = MoneyText.input(session.availableForDailySpending) }
                updateSplit()
            }
            .onChange(of: shareToFamily) { updateSplit() }
            .onChange(of: amount) { updateSplit() }
            .onChange(of: source) { updateSplit() }
        }
    }

    private var amountView: some View {
        Text("\(amount.isEmpty ? "0" : MoneyText.grouped(amount)) ₽")
            .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(money == nil ? .tertiary : .primary)
            .lineLimit(1).minimumScaleFactor(0.4).fixedSize(horizontal: false, vertical: true)
            .contentTransition(.numericText()).animation(FolkiMotion.quick, value: amount)
    }

    private func updateSplit() {
        split = isContribution ? EnvelopeDistribution(incoming: money ?? Money(minorUnits: 0), fills: [:])
            : distributesExisting ? session.existingDistribution(of: envelopeBase) : session.distribution(of: envelopeBase)
    }

    private var amountPage: some View {
        VStack(spacing: FolkiSpacing.item) {
            ScrollView {
                VStack(spacing: FolkiSpacing.page) {
                    amountView.padding(.top, FolkiSpacing.page)
                    if scope == .family { familySources }
                    if let before = session.result {
                        VStack(spacing: 8) {
                            Text("Бюджет до внесения").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            LabeledContent("Свободно", value: MoneyText.whole(before.monthlyRemaining))
                            LabeledContent("Сегодня можно", value: MoneyText.whole(before.todayRemaining))
                            LabeledContent("Дней осталось", value: "\(before.remainingDays)")
                        }
                        .font(.subheadline).padding(FolkiSpacing.card)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
                    }
                    if money != nil {
                        impact(before: session.result, after: projected)
                        if !isContribution { allocationSummary }
                    } else {
                        Text("Покажу, куда разойдутся деньги")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                }.padding(.vertical, FolkiSpacing.xs)
            }.scrollBounceBehavior(.basedOnSize)
            AmountKeypad(text: $amount)
            Button("Проверить распределение") {
                guard money != nil else { FolkiFeedback.boundary(); return }
                updateSplit()
                move { splitting = true }
            }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(money == nil)
        }
    }

    private var familySources: some View {
        VStack(spacing: 0) {
            radio(.contribution, "Из моего личного", "Это вклад: в личном станет меньше")
            Divider().padding(.leading, 44)
            radio(.income, "Общие поступления", "Деньги пришли сразу в семью")
        }
        .padding(.horizontal, FolkiSpacing.card)
        .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
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
        VStack(spacing: FolkiSpacing.item) {
            // The day before and after stays in sight while the sliders move.
            if !isContribution { impact(before: session.result, after: projected) }
            ScrollView {
                VStack(spacing: FolkiSpacing.page) {
                    Button { if !distributesExisting { move { splitting = false } } } label: {
                        Text(money.map(MoneyText.whole) ?? "—").font(.largeTitle.bold()).monospacedDigit()
                    }.buttonStyle(.plain).accessibilityHint(distributesExisting ? "Текущий остаток бюджета" : "Изменить сумму")
                    if isContribution {
                        Text("Перевод из личного бюджета в семейный").font(.subheadline).foregroundStyle(.secondary)
                        if let money, let personalBefore = personal.result {
                            impact(before: personalBefore, after: personal.previewTransfer(money, kind: .contributionOut))
                        }
                    } else {
                        if !distributesExisting && scope == .personal && hasFamily { shareRow }
                        if openEnvelopes.isEmpty {
                            Text("Конвертов для пополнения нет — поступление останется на жизнь")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(openEnvelopes) { envelope in envelopeSlider(envelope) }
                        allocationSummary
                    }
                    if isContribution { impact(before: session.result, after: projected) }
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                }.padding(.vertical, FolkiSpacing.item)
            }.scrollBounceBehavior(.basedOnSize)
            Button(distributesExisting ? "Распределить" : isContribution ? "Перевести в семью" : "Внести деньги", action: save)
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(isSaving || projected == nil)
        }
    }

    private var allocationSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(distributesExisting ? "Деньги в бюджете сейчас" : "Куда пойдут деньги").font(.headline)
            if familyShare.minorUnits > 0 { LabeledContent("В семью", value: MoneyText.whole(familyShare)) }
            let total = split.fills.values.reduce(Int64(0)) { $0 + $1.minorUnits }
            LabeledContent("В конверты", value: MoneyText.whole(Money(minorUnits: total)))
            livingRow
            if let money {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        if familyShare.minorUnits > 0 {
                            Capsule().fill(RingPalette.family.start).frame(width: max(0, geometry.size.width - 4) * Double(familyShare.minorUnits) / Double(money.minorUnits))
                        }
                        if total > 0 {
                            Capsule().fill(RingPalette.personal.start).frame(width: max(0, geometry.size.width - 4) * Double(total) / Double(money.minorUnits))
                        }
                        Capsule().fill(Color.folkiAccent)
                    }
                }.frame(height: 7)
            }
        }
        .font(.subheadline).padding(FolkiSpacing.card)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
    }

    private func impact(before: DailyBudgetSnapshot?, after: DailyBudgetSnapshot?) -> some View {
        VStack(spacing: 10) {
            Text("Бюджет на день · до → после").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                Text(before.map { MoneyText.whole($0.todayRemaining) } ?? "—").foregroundStyle(.secondary)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(after.map { MoneyText.whole($0.todayRemaining) } ?? "—").foregroundStyle(Color.folkiAccent)
            }.font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            if let future = after?.futureAllocation {
                Text("Дальше в день: \(MoneyText.whole(future.firstDayAmount))").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(FolkiSpacing.card)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
    }

    private func receiptPage(_ receipt: Receipt) -> some View {
        VStack(spacing: FolkiSpacing.page) {
            ScrollView {
                VStack(spacing: FolkiSpacing.page) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Color.folkiAccent)
                    Text(distributesExisting ? "Бюджет распределён" : "Деньги внесены").font(.title.bold())
                    Text(MoneyText.whole(receipt.amount)).font(.largeTitle.bold()).monospacedDigit()
                    VStack(spacing: 12) {
                        if receipt.share.minorUnits > 0 { LabeledContent("В семью", value: MoneyText.whole(receipt.share)) }
                        ForEach(receipt.lines) { line in LabeledContent(line.name, value: MoneyText.whole(line.amount)) }
                        LabeledContent("На жизнь", value: MoneyText.whole(receipt.living))
                    }.padding(FolkiSpacing.card).glassEffect(.regular, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
                    impact(before: receipt.before, after: receipt.after)
                }.padding(.vertical, FolkiSpacing.page)
            }
            Button("Готово") { dismiss() }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
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
                        percent: family.contributionPercent, urgentFamilyShortfalls: family.urgentShortfalls,
                        personalObligations: personal.mandatoryObligations) } ?? Money(minorUnits: 0))))
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .tint(RingPalette.family.start)
        .padding(FolkiSpacing.card)
        .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
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
                EnvelopeIcon(session: session, envelope: envelope, size: 28)
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
        .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
    }

    private func dueLine(_ envelope: RecurringEnvelope) -> String {
        if let target = envelope.target {
            return String(localized: "Копилка · \(MoneyText.whole(session.envelopeBalance(envelope))) из \(MoneyText.whole(target))")
        }
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
        guard let money, !isSaving, receipt == nil else { return }
        isSaving = true
        defer { isSaving = false }
        let before = session.result
        let lines = openEnvelopes.compactMap { envelope -> Line? in
            guard let fill = split.fills[envelope.id], fill.minorUnits > 0 else { return nil }
            return Line(id: envelope.id, name: envelope.name, amount: fill)
        }
        let share = familyShare
        let livingAmount = isContribution ? money : living
        do {
            if distributesExisting {
                try session.distributeAvailable(split.fills, operationID: operationID)
            } else if isContribution {
                let free = personal.result?.monthlyRemaining.nonnegative ?? Money(minorUnits: 0)
                guard money.minorUnits <= free.minorUnits else {
                    errorMessage = String(localized: "В личном свободно только \(MoneyText.whole(free))")
                    FolkiFeedback.boundary(); return
                }
                try personal.contribute(money, to: family, linkID: operationID)
            } else {
                try session.deposit(money, fills: split.fills, familyShare: share, family: family, operationID: operationID)
            }
            FolkiFeedback.saved()
            move { receipt = Receipt(amount: money, living: livingAmount, share: share, lines: lines, before: before, after: session.result) }
        } catch {
            errorMessage = String(localized: "Не получилось сохранить распределение. Деньги не перемещены — попробуй ещё раз.")
        }
    }
}
