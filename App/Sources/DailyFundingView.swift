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
    /// "+ конверты": the deposit also fills the envelopes; "всё на жизнь": it all stays as living money.
    @State private var toEnvelopes = true
    @State private var split = EnvelopeDistribution(incoming: Money(minorUnits: 0), fills: [:])
    @State private var operationID = UUID()
    @State private var errorMessage: String?
    @State private var receipt: Receipt?
    @State private var isSaving = false
    /// Bills marked "Уже оплачено" here, as they were before moving to their next date, so "Вернуть" can undo it.
    @State private var paidOutside: [RecurringEnvelope] = []
    private struct Line: Identifiable { let id: UUID; let name: String; let amount: Money; let symbol: String; let color: Color }
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
        let paid = Set(paidOutside.map(\.id))
        return session.envelopes.filter { !paid.contains($0.id) && ((try? $0.shortfall(balance: session.envelopeBalance($0)).minorUnits) ?? 0) > 0 }
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
                        dots: [Color.folkiPersonal, Color.folkiFamily])
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
            .onChange(of: toEnvelopes) { updateSplit() }
            .onChange(of: amount) { updateSplit() }
            .onChange(of: source) { updateSplit() }
        }
    }

    private var amountView: some View {
        Text("\(amount.isEmpty ? "0" : MoneyText.grouped(amount)) ₽")
            .font(FolkiFont.money(FolkiFont.inputSize)).monospacedDigit()
            .foregroundStyle(money == nil ? .tertiary : .primary)
            .lineLimit(1).minimumScaleFactor(0.4).fixedSize(horizontal: false, vertical: true)
            .contentTransition(.numericText()).animation(FolkiMotion.quick, value: amount)
    }

    private func updateSplit() {
        split = isContribution || (!distributesExisting && !toEnvelopes) ? EnvelopeDistribution(incoming: money ?? Money(minorUnits: 0), fills: [:])
            : distributesExisting ? session.existingDistribution(of: envelopeBase) : session.distribution(of: envelopeBase)
    }
    /// Whether the deposit has a second step: envelopes to fill, or the family share to decide.
    private var needsSplit: Bool { !isContribution && ((toEnvelopes && !openEnvelopes.isEmpty) || (scope == .personal && hasFamily)) }

    private var amountPage: some View {
        VStack(spacing: FolkiSpacing.item) {
            ScrollView {
                VStack(spacing: FolkiSpacing.page) {
                    amountView
                    if scope == .family { familySources }
                    // What this money does to the day: the same line as when spending.
                    if let before = session.result {
                        SpendConsequence(session: session, before: before, after: money == nil ? nil : projected,
                                         envelope: nil, money: money, tint: tint)
                    }
                    if !isContribution && !openEnvelopes.isEmpty {
                        FolkiSegmentedPicker(title: String(localized: "Куда внести"), selection: $toEnvelopes,
                            options: [(String(localized: "всё на жизнь"), false), (String(localized: "+ конверты"), true)])
                    }
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                }.padding(.vertical, FolkiSpacing.xs)
            }.scrollBounceBehavior(.basedOnSize)
            AmountKeypad(text: $amount)
            Button(needsSplit ? String(localized: "Дальше") : String(localized: "Внести деньги")) {
                guard money != nil else { FolkiFeedback.boundary(); return }
                updateSplit()
                if needsSplit { move { splitting = true } } else { save() }
            }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(money == nil || isSaving)
        }
    }

    private var familySources: some View {
        VStack(spacing: 0) {
            radio(.contribution, "Из моего личного", "Это вклад: в личном станет меньше")
            Divider().padding(.leading, 44)
            radio(.income, "Общие поступления", "Деньги пришли сразу в семью")
        }
        .padding(.horizontal, FolkiSpacing.card)
        .folkiTileBackground()
    }

    private func radio(_ value: FamilySource, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        Button {
            FolkiFeedback.selection(); source = value; errorMessage = nil
        } label: {
            HStack(spacing: FolkiSpacing.item) {
                Image(systemName: source == value ? "checkmark.circle.fill" : "circle")
                    .font(FolkiFont.icon).foregroundStyle(source == value ? Color.folkiAccent : Color.secondary)
                VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
                    Text(title).font(FolkiFont.body).foregroundStyle(Color.folkiInk)
                    Text(detail).folkiText(.footnote)
                }
                Spacer(minLength: 0)
            }.frame(minHeight: 60).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(source == value ? .isSelected : [])
    }

    private var splitPage: some View {
        VStack(spacing: FolkiSpacing.item) {
            // The day before and after stays in sight while the sliders move.
            if !isContribution, let before = session.result {
                SpendConsequence(session: session, before: before, after: projected, envelope: nil, money: money, tint: tint)
            }
            ScrollView {
                VStack(spacing: FolkiSpacing.page) {
                    Button { if !distributesExisting { move { splitting = false } } } label: {
                        Text(money.map(MoneyText.whole) ?? "—").font(FolkiFont.moneyLarge).monospacedDigit()
                    }.buttonStyle(.plain).accessibilityHint(distributesExisting ? "Текущий остаток бюджета" : "Изменить сумму")
                    if isContribution {
                        // Both sides of a contribution: the personal day gives, the family day gets.
                        if let money, let personalBefore = personal.result {
                            SpendConsequence(session: personal, before: personalBefore, after: personal.previewTransfer(money, kind: .contributionOut),
                                             envelope: nil, money: money, tint: Color.folkiPersonal)
                        }
                    } else {
                        if !distributesExisting && scope == .personal && hasFamily { shareRow }
                        if toEnvelopes || distributesExisting {
                            ForEach(openEnvelopes) { envelope in envelopeSlider(envelope) }
                        }
                        ForEach(paidOutside) { envelope in paidRow(envelope) }
                    }
                    if isContribution, let before = session.result {
                        SpendConsequence(session: session, before: before, after: projected, envelope: nil, money: money, tint: Color.folkiFamily)
                    }
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                }.padding(.vertical, FolkiSpacing.item)
            }.scrollBounceBehavior(.basedOnSize)
            if distributesExisting && !split.fills.values.contains(where: { $0.minorUnits > 0 }) {
                // Nothing to move, for example every bill is already paid: the sheet just closes.
                Button("Готово") { dismiss() }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            } else {
                Button(distributesExisting ? "Распределить" : isContribution ? "Перевести в семью" : "Внести деньги", action: save)
                    .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(isSaving || projected == nil)
            }
        }
    }

    private var tint: Color { scope == .personal ? Color.folkiPersonal : Color.folkiFamily }

    private func envelopeLook(_ envelope: RecurringEnvelope) -> (symbol: String, color: Color) {
        let category = session.catalog.category(for: envelope.categoryID ?? BuiltInCategory.other.id)
        return (envelope.symbol ?? category.symbol, (envelope.color ?? category.color).color)
    }

    private func receiptRow(symbol: String, color: Color, name: String, amount: Money) -> some View {
        HStack(spacing: FolkiSpacing.item) {
            CategoryIcon(symbol: symbol, color: color, size: 30)
            Text(name).font(FolkiFont.body).foregroundStyle(Color.folkiInk).lineLimit(1)
            Spacer(minLength: FolkiSpacing.xs)
            Text("+\(MoneyText.whole(amount))").font(FolkiFont.moneyRow).monospacedDigit().foregroundStyle(Color.folkiInk)
        }
        .padding(.vertical, FolkiSpacing.item)
    }

    private func receiptPage(_ receipt: Receipt) -> some View {
        VStack(spacing: FolkiSpacing.page) {
            ScrollView {
                VStack(spacing: FolkiSpacing.page) {
                    Image(systemName: "checkmark.circle.fill").font(FolkiFont.symbol(64)).foregroundStyle(Color.folkiAccent)
                    Text(distributesExisting ? "Бюджет распределён" : "Деньги внесены").font(FolkiFont.section)
                    Text(MoneyText.whole(receipt.amount)).font(FolkiFont.moneyLarge).monospacedDigit()
                    if let before = receipt.before {
                        SpendConsequence(session: session, before: before, after: receipt.after, envelope: nil, money: receipt.amount, tint: tint)
                    }
                    VStack(spacing: 0) {
                        if receipt.share.minorUnits > 0 {
                            receiptRow(symbol: "heart.fill", color: Color.folkiFamily, name: String(localized: "В семью"), amount: receipt.share)
                        }
                        ForEach(receipt.lines) { line in receiptRow(symbol: line.symbol, color: line.color, name: line.name, amount: line.amount) }
                        receiptRow(symbol: "wallet.bifold.fill", color: tint, name: String(localized: "На жизнь"), amount: receipt.living)
                    }
                    .padding(.horizontal, FolkiSpacing.card).folkiTileBackground()
                }.padding(.vertical, FolkiSpacing.page)
            }
            Button("Готово") { dismiss() }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        }
    }

    private var shareRow: some View {
        Toggle(isOn: $shareToFamily.animation(FolkiMotion.quick)) {
            HStack(spacing: FolkiSpacing.item) {
                Image(systemName: "heart.fill").foregroundStyle(Color.folkiFamily)
                    .frame(width: 36, height: 36).background(Color.folkiFamily.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
                    Text("В семью \(family.contributionPercent)%").font(FolkiFont.headline)
                    Text(MoneyText.whole(shareToFamily ? familyShare : (money.flatMap { try? ContributionAdvisor.suggestion(topUp: $0,
                        percent: family.contributionPercent, urgentFamilyShortfalls: family.urgentShortfalls,
                        personalObligations: personal.mandatoryObligations) } ?? Money(minorUnits: 0))))
                        .folkiText(.footnote).monospacedDigit()
                }
            }
        }
        .tint(Color.folkiFamily)
        .padding(FolkiSpacing.card)
        .folkiTileBackground()
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
        let full = fill.minorUnits >= need.minorUnits && need.minorUnits > 0
        return VStack(alignment: .leading, spacing: FolkiSpacing.xs) {
            HStack(spacing: FolkiSpacing.item) {
                EnvelopeIcon(session: session, envelope: envelope, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(envelope.name).font(FolkiFont.headline).foregroundStyle(Color.folkiInk).lineLimit(1)
                    Text(dueLine(envelope)).font(FolkiFont.footnote).foregroundStyle(urgency == .calm || urgency == .funded ? Color.folkiSecondary : urgency.color)
                }
                Spacer(minLength: FolkiSpacing.xs)
                // What goes in now; a check once this deposit makes the envelope whole.
                Text("+\(MoneyText.whole(fill))").font(FolkiFont.moneyRow).monospacedDigit()
                    .foregroundStyle(fill.minorUnits > 0 ? Color.folkiInk : Color.folkiTertiary)
                    .contentTransition(.numericText(value: Double(fill.minorUnits)))
                Image(systemName: full ? "checkmark.circle.fill" : "circle").font(FolkiFont.icon)
                    .foregroundStyle(full ? Color.folkiAccent : Color.folkiTertiary)
                    .animation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion), value: full)
            }
            Slider(value: binding, in: 0...max(1, Double(need.roundedUpToWholeUnits.minorUnits / 100)), step: 1)
                .tint(envelopeLook(envelope).color)
                .accessibilityLabel(envelope.name)
                .accessibilityValue(MoneyText.whole(fill))
            // Money already set aside elsewhere, or the bill already paid: this time is skipped, not funded.
            if isDueThisPeriod(envelope) {
                Button("Уже оплачено") { markPaid(envelope) }
                    .font(FolkiFont.label).foregroundStyle(Color.folkiAccent)
                    .buttonStyle(.plain).frame(minHeight: 32)
            }
        }
        .padding(FolkiSpacing.card)
        .folkiTileBackground()
    }

    private func isDueThisPeriod(_ envelope: RecurringEnvelope) -> Bool {
        guard !envelope.isSavings, let end = session.household?.period.endExclusive else { return false }
        return envelope.nextDue < end
    }

    private func paidRow(_ original: RecurringEnvelope) -> some View {
        let next = session.envelopes.first { $0.id == original.id }?.nextDue ?? original.nextDue
        return HStack(spacing: FolkiSpacing.item) {
            Image(systemName: "checkmark.circle.fill").font(FolkiFont.icon).foregroundStyle(Color.folkiAccent)
            VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
                Text(original.name).font(FolkiFont.headline).lineLimit(1)
                Text("Следующий платёж жду \(next.formatted(.dateTime.day().month(.abbreviated)))")
                    .folkiText(.footnote)
            }
            Spacer(minLength: FolkiSpacing.xs)
            Button("Вернуть") { undoPaid(original) }
                .font(FolkiFont.label).foregroundStyle(Color.folkiAccent)
                .buttonStyle(.plain).frame(minHeight: 44)
        }
        .padding(FolkiSpacing.card)
        .folkiTileBackground()
        .transition(.opacity)
    }

    private func markPaid(_ envelope: RecurringEnvelope) {
        do {
            try session.skipEnvelope(envelope)
            FolkiFeedback.selection()
            errorMessage = nil
            move { paidOutside.append(envelope) }
            updateSplit()
        } catch { errorMessage = String(localized: "Не получилось отметить платёж. Попробуй ещё раз.") }
    }

    private func undoPaid(_ original: RecurringEnvelope) {
        do {
            try session.updateEnvelope(original)
            errorMessage = nil
            move { paidOutside.removeAll { $0.id == original.id } }
            updateSplit()
        } catch { errorMessage = String(localized: "Не получилось вернуть платёж. Попробуй ещё раз.") }
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
            let look = envelopeLook(envelope)
            return Line(id: envelope.id, name: envelope.name, amount: fill, symbol: look.symbol, color: look.color)
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
