import SwiftUI
import UIKit
import FolkiDuoCore

/// What an operation does to a budget: today's remainder and the daily amount for the rest of the month.
struct ImpactLines: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let before: DailyBudgetSnapshot
    /// Nil until an amount is entered.
    let after: DailyBudgetSnapshot?
    var label: String? = nil

    var body: some View {
        let result = after ?? before
        VStack(spacing: 4) {
            if let label { Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            today(result.todayRemaining)
            nextDays(result)
        }
        .multilineTextAlignment(.center).monospacedDigit()
        .animation(reduceMotion ? nil : FolkiMotion.quick, value: result.todayRemaining)
    }

    @ViewBuilder private func today(_ remaining: Money) -> some View {
        if remaining.minorUnits < 0 {
            Text("Сегодня \(MoneyText.whole(remaining))").font(.subheadline.weight(.semibold)).foregroundStyle(Color.folkiOver)
        } else {
            Text("\(after == nil ? String(localized: "Сегодня можно") : String(localized: "Сегодня останется")) \(MoneyText.whole(remaining))").font(.subheadline)
        }
    }

    @ViewBuilder private func nextDays(_ result: DailyBudgetSnapshot) -> some View {
        if result.monthlyRemaining.minorUnits < 0 {
            Text("Период превышен на \(MoneyText.whole(Money(minorUnits: -result.monthlyRemaining.minorUnits).roundedUpToWholeUnits))")
                .font(.footnote).foregroundStyle(Color.folkiOver)
        } else if let future = result.futureAllocation {
            // Less than a rouble shows as "(±0 ₽)" in red and reads as a warning: no note then.
            let change = after == nil ? nil : (try? result.nextDaysChange(since: before)).flatMap { abs($0.minorUnits) < 100 ? nil : $0 }
            // A spend within today's money is normal: red only once the day itself goes over.
            let changeText = Text(verbatim: change.map { " (\(signed($0)))" } ?? "")
                .foregroundStyle(result.todayRemaining.minorUnits < 0 && change.map { $0.minorUnits < 0 } == true ? Color.folkiOver : .secondary)
            Text("Дальше в день: \(MoneyText.whole(future.firstDayAmount))\(changeText)").font(.footnote)
        } else {
            Text("Последний день периода").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func signed(_ money: Money) -> String {
        // Round toward zero so a small change never reads larger than it is.
        let rounded = money.minorUnits < 0 ? Money(minorUnits: -money.minorUnits).roundedDownToWholeUnits : money.roundedDownToWholeUnits
        if rounded.minorUnits == 0 { return "±0 ₽" }
        return (money.minorUnits < 0 ? "−" : "+") + MoneyText.whole(rounded)
    }
}

/// Spend in three taps: amount → category (optional) → «Записать».
/// The same sheet edits a spend already recorded: prefilled, with the change shown against today.
struct QuickSpendView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    let entryKind: TransactionKind
    var onSaved: (() -> Void)? = nil
    /// A plain spend was saved: the main screen offers to take it back.
    var onRecorded: ((LedgerRecord, BudgetSession) -> Void)? = nil
    /// Editing: the record and the budget it belongs to; the budget switch is hidden then.
    private let editing: LedgerRecord?
    private let editingSession: BudgetSession?
    /// Editing: "Удалить трату" was tapped; the main screen deletes it and offers "Вернуть".
    var onDelete: ((LedgerRecord, BudgetSession) -> Void)? = nil
    @State private var incomeScopeRaw: String
    @AppStorage("FolkiLastSpendScope") private var scopeRaw = BudgetScope.personal.rawValue
    @State private var amount = ""
    @State private var categoryID: UUID?
    @State private var envelopeID: UUID?
    @State private var date: Date
    @State private var showingAllCategories = false
    @State private var settingUp = false
    @State private var recordID = UUID()
    @State private var errorMessage: String?
    /// Editing: the first digit replaces the recorded amount instead of being added to it.
    @State private var replacesAmount = false
    @ScaledMetric(relativeTo: .body) private var chipHeight: CGFloat = 44
    /// The amount grows with the text size, like everything else on the sheet.
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 52

    init(personal: BudgetSession, family: BudgetSession, entryKind: TransactionKind = .expense, initialScope: BudgetScope = .personal,
         onSaved: (() -> Void)? = nil, onRecorded: ((LedgerRecord, BudgetSession) -> Void)? = nil) {
        self.personal = personal; self.family = family; self.entryKind = entryKind; self.onSaved = onSaved; self.onRecorded = onRecorded
        editing = nil; editingSession = nil
        _incomeScopeRaw = State(initialValue: initialScope.rawValue)
        _date = State(initialValue: personal.referenceDate)
    }

    init(editing record: LedgerRecord, in session: BudgetSession, personal: BudgetSession, family: BudgetSession,
         onDelete: @escaping (LedgerRecord, BudgetSession) -> Void) {
        self.personal = personal; self.family = family; entryKind = .expense; self.onDelete = onDelete
        editing = record; editingSession = session
        _incomeScopeRaw = State(initialValue: session.scope.rawValue)
        _date = State(initialValue: record.transaction.date)
        _amount = State(initialValue: MoneyText.input(record.transaction.amount))
        _categoryID = State(initialValue: record.categoryID)
        _replacesAmount = State(initialValue: true)
    }

    private var keypadText: Binding<String> {
        Binding(get: { amount }, set: { new in
            defer { replacesAmount = false }
            guard replacesAmount, new.count > amount.count, let key = new.last else { amount = new; return }
            amount = key == "," ? "0," : String(key)
        })
    }

    private var isIncome: Bool { entryKind == .income }
    private var activeScopeRaw: String { family.household == nil ? BudgetScope.personal.rawValue : (isIncome ? incomeScopeRaw : scopeRaw) }
    private var scopeSelection: Binding<String> { isIncome ? $incomeScopeRaw : $scopeRaw }
    private var scope: BudgetScope { BudgetScope(rawValue: activeScopeRaw) ?? .personal }
    private var session: BudgetSession { editingSession ?? (scope == .personal ? personal : family) }
    private var money: Money? {
        guard let money = try? Money(parsing: amount.hasSuffix(",") ? String(amount.dropLast()) : amount),
              money.minorUnits > 0 else { return nil }
        return money
    }
    private var draft: LedgerRecord? {
        guard let money, let payer = editing?.transaction.payerID ?? session.authorID else { return nil }
        return try? session.draft(amount: money, title: editing?.title ?? "", payerID: payer, date: date, kind: entryKind,
            categoryID: envelope?.categoryID ?? categoryID ?? BuiltInCategory.other.id,
            funding: .flexible, editing: editing, newRecordID: recordID)
    }
    /// A category tracks statistics; only an explicitly selected envelope supplies money.
    private var envelope: RecurringEnvelope? {
        guard !isIncome, let envelopeID else { return nil }
        return session.envelopes.first { $0.id == envelopeID }
    }
    private var after: DailyBudgetSnapshot? {
        guard let draft else { return nil }
        if let envelope, let money {
            // Only what the envelope cannot cover reaches the day.
            let missing = max(0, money.minorUnits - session.envelopeBalance(envelope).minorUnits)
            if missing == 0 { return session.result }
            guard let rest = try? session.draft(amount: Money(minorUnits: missing), title: "", payerID: draft.transaction.payerID,
                date: date, kind: entryKind, categoryID: categoryID ?? BuiltInCategory.other.id, funding: .flexible, newRecordID: recordID)
            else { return nil }
            return try? session.preview(rest)
        }
        return try? session.preview(draft, editing: editing)
    }

    var body: some View {
        NavigationStack {
            FolkiEntryLayout { availableHeight in
                SpendContentLayout(availableHeight: availableHeight) {
                    if family.household != nil && editing == nil { FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: scopeSelection,
                        options: BudgetScope.allCases.map { ($0.title, $0.rawValue) }, minimumHeight: 48)
                        .padding(.horizontal, FolkiSpacing.page)
                    .onChange(of: activeScopeRaw) { categoryID = nil; envelopeID = nil; preselectCategory(); recordID = UUID() }
                    }
                    if let before = session.result {
                        Text("\(amount.isEmpty ? "0" : MoneyText.grouped(amount)) ₽")
                            .font(.system(size: amountSize, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(money == nil ? .tertiary : .primary)
                            .lineLimit(1).minimumScaleFactor(0.3)
                            .frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
                            .padding(.horizontal, FolkiSpacing.page)
                            .contentTransition(reduceMotion ? .identity : .numericText()).animation(reduceMotion ? nil : FolkiMotion.quick, value: amount)
                            .accessibilityLabel("Сумма \(money.map(MoneyText.string) ?? "не введена")")
                        ImpactLines(before: before, after: after)
                            .padding(.vertical, 12).padding(.horizontal, FolkiSpacing.card).frame(maxWidth: .infinity)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
                            .padding(.horizontal, FolkiSpacing.page)
                        if !isIncome {
                            // Choosing an envelope makes sense only when there is one, and not for a spend already recorded.
                            if editing == nil && !session.envelopes.isEmpty { spendSource }
                            if envelope == nil { categoryChips.frame(height: chipHeight + 12) }
                        }
                        if let envelope { envelopeLine(envelope) }
                        if isIncome {
                            Text("Поступление увеличит свободные деньги \(scope == .personal ? "личного" : "семейного") бюджета. Это не перевод из другого бюджета.")
                                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, FolkiSpacing.page)
                        }
                        if let errorMessage {
                            FolkiErrorMessage(message: errorMessage).padding(.horizontal, FolkiSpacing.page)
                        }
                    } else {
                        ContentUnavailableView {
                            Label("\(scope.title) бюджет не настроен", systemImage: "wallet.bifold")
                        } description: {
                            Text("Задай сумму на период — я посчитаю твой день")
                        } actions: {
                            Button("Настроить") { settingUp = true }.buttonStyle(FolkiPrimaryButtonStyle())
                        }
                    }
                }
            } keypad: {
                if session.result != nil {
                    AmountKeypad(text: keypadText).padding(.horizontal, FolkiSpacing.page)
                }
            }
            // Outside the scrolling area: with large text the keypad scrolls, the save button stays in reach.
            .safeAreaInset(edge: .bottom, spacing: 12) {
                if session.result != nil { VStack(spacing: 0) {
                    Button(action: save) {
                        Text(isIncome ? String(localized: "Внести деньги") : editing != nil ? String(localized: "Сохранить") : String(localized: "Записать")).font(.headline)
                            .frame(maxWidth: .infinity).frame(minHeight: FolkiSpacing.primaryButton)
                            .foregroundStyle(.white)
                            .glassEffect(.regular.tint(Color.folkiAccent.opacity(after == nil ? 0.35 : 1)).interactive(), in: Capsule())
                    }.buttonStyle(FolkiPressStyle()).disabled(after == nil)
                    .padding(.horizontal, FolkiSpacing.page).padding(.bottom, editing == nil ? FolkiSpacing.card : 0)
                    if let editing, let editingSession {
                        Button("Удалить трату", role: .destructive) { dismiss(); onDelete?(editing, editingSession) }
                            .font(.subheadline.weight(.medium)).foregroundStyle(Color.folkiOver)
                            .frame(minHeight: 44).padding(.bottom, FolkiSpacing.xs)
                    }
                } }
            }
            .background { FolkiBackground() }
            .navigationTitle(editing.map { String(localized: "Трата · \($0.transaction.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))") } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { FolkiCloseButton { dismiss() } }
            }
            .sheet(isPresented: $showingAllCategories) {
                CategoryGridSheet(session: session, selection: $categoryID, envelopeSelection: $envelopeID).presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $settingUp) { DailyFundingView(personal: personal, family: family, initialScope: scope) }
            .onAppear {
                if UserDefaults.standard.string(forKey: "FolkiLastSpendScope") == nil && family.hasFunding && !personal.hasFunding {
                    scopeRaw = BudgetScope.family.rawValue
                }
                prepareBudget()
                preselectCategory()
            }
            .onChange(of: activeScopeRaw) { prepareBudget() }
        }
        .tint(Color.folkiAccent)
    }

    private var spendSource: some View {
        Button { showingAllCategories = true } label: {
            HStack(spacing: FolkiSpacing.item) {
                Image(systemName: envelope == nil ? "wallet.bifold" : "tray.full.fill")
                VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
                    Text(envelope.map { String(localized: "Из конверта «\($0.name)»") } ?? String(localized: "Из денег на жизнь"))
                        .font(.subheadline.weight(.semibold))
                    Text(envelope == nil ? "Можно взять из конверта" : "Изменить источник")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }.padding(FolkiSpacing.item)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
        }.buttonStyle(.plain).padding(.horizontal, FolkiSpacing.page)
    }

    private var categoryChips: some View {
        let frequent = session.frequentCategories()
        let selected = categoryID.map { session.catalog.category(for: $0) }
        // A category picked under "Ещё" takes the third chip's place for this spend.
        let chips = selected.map { frequent.contains($0) ? frequent : Array(frequent.prefix(2)) + [$0] } ?? frequent
        // "Ещё" stays at the edge, so the full list is in sight however long the chip names are.
        return HStack(spacing: 8) {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(chips) { category in
                    let isSelected = categoryID == category.id
                    Button { envelopeID = nil; categoryID = isSelected ? nil : category.id; FolkiFeedback.selection() } label: {
                        HStack(spacing: FolkiSpacing.xs) {
                            CategoryIcon(category: category, size: 24)
                            Text(category.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        }
                        .padding(.horizontal, FolkiSpacing.item).frame(minHeight: chipHeight)
                        .glassEffect(.regular.tint(isSelected ? category.color.color.opacity(0.25) : .clear).interactive(), in: Capsule())
                        .foregroundStyle(Color.folkiInk)
                    }
                    .buttonStyle(FolkiPressStyle()).accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }.padding(.leading, FolkiSpacing.page)
            }
        }
        Button("Ещё") { showingAllCategories = true }
            .font(.subheadline.weight(.medium)).padding(.horizontal, FolkiSpacing.card).frame(minHeight: chipHeight)
            .glassEffect(.regular.interactive(), in: Capsule()).foregroundStyle(Color.folkiInk).buttonStyle(FolkiPressStyle())
            .padding(.trailing, FolkiSpacing.page)
        }
    }

    /// A spend in a plan category counts against what is set aside for it; the day only feels the rest.
    private func envelopeLine(_ envelope: RecurringEnvelope) -> some View {
        let left = session.envelopeBalance(envelope)
        let progress = envelope.size.minorUnits > 0 ? 1 - Double(left.minorUnits) / Double(envelope.size.minorUnits) : 0
        return HStack(spacing: FolkiSpacing.item) {
            Image(systemName: "list.bullet.clipboard").font(.subheadline.weight(.semibold)).foregroundStyle(Color.folkiAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text("В конверте \(MoneyText.whole(left)) · ориентир \(MoneyText.whole(envelope.size))")
                    .font(.footnote.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                ProgressView(value: max(0, min(1, progress))).tint(Color.folkiAccent)
            }
            if let money, money.minorUnits > left.minorUnits {
                Text("+ \(MoneyText.whole(Money(minorUnits: money.minorUnits - left.minorUnits))) из денег на жизнь")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, FolkiSpacing.card).frame(minHeight: 52)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
        .padding(.horizontal, FolkiSpacing.page)
        .accessibilityElement(children: .combine)
    }

    private func save() {
        guard let draft else { return }
        let crossed = !isIncome && FolkiFeedback.crossesIntoMinus(before: session.result?.todayRemaining, after: after?.todayRemaining)
        do {
            if let envelope, let money {
                try session.spendFromEnvelope(envelope, amount: money, operationID: recordID)
                FolkiFeedback.saved(crossedIntoMinus: crossed)
                dismiss(); onSaved?()
                return
            }
            try session.save(draft, editing: editing)
            FolkiFeedback.saved(crossedIntoMinus: crossed)
            dismiss()
            onSaved?()
            if editing == nil, let saved = session.records.first(where: { $0.id == draft.id }) { onRecorded?(saved, session) }
        } catch LedgerError.conflict {
            errorMessage = String(localized: "Трату уже изменили на другом устройстве. Закрой и открой её заново.")
        } catch {
            errorMessage = String(localized: "Не получилось записать. Сумма осталась здесь, попробуй ещё раз.")
        }
    }
    /// Zero taps for the usual case: the chip most used around this hour is picked in advance.
    private func preselectCategory() {
        guard !isIncome, envelopeID == nil, categoryID == nil else { return }
        categoryID = session.likelyCategory(among: session.frequentCategories(), at: .now)?.id
    }
    private func prepareBudget() {
        // An edited spend keeps its own date.
        do { try session.ensureDailyPeriod(); if editing == nil { date = session.referenceDate } }
        catch { errorMessage = String(localized: "Не получилось открыть бюджет. Попробуй ещё раз.") }
    }
}

/// Digits, one comma and up to two decimals; the system keyboard would cover the impact lines.
struct AmountKeypad: View {
    @Binding var text: String
    @ScaledMetric(relativeTo: .title2) private var keyHeight: CGFloat = 56
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ",", "0", "⌫"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(keys, id: \.self) { key in
                Button { press(key) } label: {
                    Group {
                        if key == "⌫" { Image(systemName: "delete.left") } else { Text(key) }
                    }
                    .font(.system(.title2, design: .rounded, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: keyHeight)
                    // A solid key, as in the spec: glass keys merge inside glass containers and
                    // materialize after the rest of a page during transitions.
                    .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: FolkiSpacing.card, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: FolkiSpacing.card, style: .continuous))
                }
                .buttonStyle(FolkiPressStyle(scale: 0.92))
                .accessibilityLabel(key == "⌫" ? String(localized: "Стереть") : key == "," ? String(localized: "Запятая") : key)
            }
        }
    }

    private func press(_ key: String) {
        let previous = text
        defer { text != previous ? FolkiFeedback.key() : FolkiFeedback.boundary() }
        switch key {
        case "⌫": if !text.isEmpty { text.removeLast() }
        case ",":
            guard !text.contains(",") else { return }
            text = (text.isEmpty ? "0" : text) + ","
        default:
            if let comma = text.firstIndex(of: ",") {
                guard text.distance(from: comma, to: text.endIndex) <= 2 else { return }
            } else {
                guard text.count < 9 else { return }
                if text == "0" { text = "" }
            }
            text += key
        }
    }
}

struct CategoryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    @Binding var selection: UUID?

    var body: some View {
        NavigationStack {
            List(session.catalog.selectable) { category in
                Button { selection = category.id; dismiss() } label: {
                    HStack(spacing: 12) {
                        CategoryIcon(category: category)
                        Text(category.name)
                        Spacer()
                        if selection == category.id { Image(systemName: "checkmark").foregroundStyle(Color.folkiAccent) }
                    }.frame(minHeight: 52).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .folkiFormLayout()
            .navigationTitle("Категория").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { CategoriesView(session: session) } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Настроить категории")
                }
            }
        }
    }
}

/// Distribute the fields over all space above the keypad, scrolling when they need more room.
private struct SpendContentLayout: Layout {
    let availableHeight: CGFloat
    private func metrics(width: CGFloat, subviews: Subviews) -> (heights: [CGFloat], gap: CGFloat, total: CGFloat) {
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let count = CGFloat(max(0, subviews.count - 1))
        let gap = count > 0 ? max(14, (availableHeight - heights.reduce(0, +)) / count) : 0
        return (heights, gap, max(availableHeight, heights.reduce(0, +) + gap * count))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 350
        return CGSize(width: width, height: metrics(width: width, subviews: subviews).total)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = metrics(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: sizes.heights[index]))
            y += sizes.heights[index] + sizes.gap
        }
    }
}

/// "Ещё": every category as a grid of round icons, like Reminders. Picking one closes the sheet.
struct CategoryGridSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    @Binding var selection: UUID?
    @Binding var envelopeSelection: UUID?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: FolkiSpacing.xs), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FolkiSpacing.page) {
                    if !session.envelopes.isEmpty {
                        Text("Конверты с деньгами").font(.headline)
                        Text("Если в конверте не хватит, разницу возьму из денег на жизнь.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(session.envelopes) { envelope in
                            Button {
                                FolkiFeedback.selection(); envelopeSelection = envelope.id
                                selection = envelope.categoryID; dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    EnvelopeIcon(session: session, envelope: envelope, size: 36)
                                    Text(envelope.name)
                                    Spacer()
                                    Text(MoneyText.whole(session.envelopeBalance(envelope))).monospacedDigit()
                                    if envelopeSelection == envelope.id { Image(systemName: "checkmark") }
                                }.font(.subheadline).padding(.vertical, 8)
                            }.buttonStyle(.plain)
                        }
                        Divider()
                    }
                    // Without envelopes there is no source to choose: only categories, no explanations.
                    if !session.envelopes.isEmpty {
                        Text("На жизнь").font(.headline)
                        Text("Категория нужна только для статистики.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                LazyVGrid(columns: columns, spacing: FolkiSpacing.page) {
                    ForEach(session.catalog.selectable) { category in
                        Button {
                            FolkiFeedback.selection(); envelopeSelection = nil; selection = category.id; dismiss()
                        } label: {
                            VStack(spacing: FolkiSpacing.xs) {
                                CategoryIcon(category: category, size: 52)
                                    .overlay { if envelopeSelection == nil && selection == category.id { Circle().strokeBorder(Color.folkiInk, lineWidth: 2).padding(-4) } }
                                Text(category.name).font(.footnote).foregroundStyle(Color.folkiInk)
                                    .lineLimit(2).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(FolkiPressStyle())
                    }
                    NavigationLink { CategoriesView(session: session) } label: {
                        VStack(spacing: FolkiSpacing.xs) {
                            Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(Color.folkiAccent)
                                .frame(width: 52, height: 52).background(Color.folkiSoft, in: Circle())
                            Text("Своя категория").font(.footnote).foregroundStyle(Color.folkiInk)
                                .lineLimit(2).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                }
                }.padding(FolkiSpacing.page)
            }
            .navigationTitle(session.envelopes.isEmpty ? String(localized: "Категория") : String(localized: "Откуда потратить")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { FolkiCloseButton { dismiss() } } }
        }
    }
}
