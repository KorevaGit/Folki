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
            if let label { Text(label).folkiText(.tag) }
            today(result.todayRemaining)
            nextDays(result)
        }
        .multilineTextAlignment(.center).monospacedDigit()
        .animation(reduceMotion ? nil : FolkiMotion.quick, value: result.todayRemaining)
    }

    @ViewBuilder private func today(_ remaining: Money) -> some View {
        if remaining.minorUnits < 0 {
            Text("Сегодня \(MoneyText.whole(remaining))").font(FolkiFont.label).foregroundStyle(Color.folkiOver)
        } else {
            Text("\(after == nil ? String(localized: "Сегодня можно") : String(localized: "Сегодня останется")) \(MoneyText.whole(remaining))").font(FolkiFont.caption)
        }
    }

    @ViewBuilder private func nextDays(_ result: DailyBudgetSnapshot) -> some View {
        if result.monthlyRemaining.minorUnits < 0 {
            Text("Период превышен на \(MoneyText.whole(Money(minorUnits: -result.monthlyRemaining.minorUnits).roundedUpToWholeUnits))")
                .font(FolkiFont.footnote).foregroundStyle(Color.folkiOver)
        } else if let future = result.futureAllocation {
            // Less than a rouble shows as "(±0 ₽)" in red and reads as a warning: no note then.
            let change = after == nil ? nil : (try? result.nextDaysChange(since: before)).flatMap { abs($0.minorUnits) < 100 ? nil : $0 }
            // A spend within today's money is normal: red only once the day itself goes over.
            let changeText = Text(verbatim: change.map { " (\(signed($0)))" } ?? "")
                .foregroundStyle(result.todayRemaining.minorUnits < 0 && change.map { $0.minorUnits < 0 } == true ? Color.folkiOver : .secondary)
            Text("Дальше в день: \(MoneyText.whole(future.firstDayAmount))\(changeText)").font(FolkiFont.footnote)
        } else {
            Text("Последний день периода").folkiText(.footnote)
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
    @State private var confirmingLarge = false
    /// The large amount was confirmed; typing another one asks again.
    @State private var largeConfirmed = false
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
    /// Where the money comes from follows what it is for: a jar picked by itself, or the bill of the chosen category
    /// (rent for «Жильё»), nearest first. Everything else is living money. An edited spend keeps its source.
    private var envelope: RecurringEnvelope? {
        guard !isIncome, editing == nil else { return nil }
        if let envelopeID { return session.envelopes.first { $0.id == envelopeID } }
        guard let categoryID, categoryID != BuiltInCategory.other.id else { return nil }
        return session.payments.filter { $0.categoryID == categoryID }.min { $0.nextDue < $1.nextDue }
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
                        options: BudgetScope.allCases.map { ($0.title, $0.rawValue) }, dots: [Color.folkiPersonal, Color.folkiFamily])
                        .padding(.horizontal, FolkiSpacing.page)
                    .onChange(of: activeScopeRaw) { categoryID = nil; envelopeID = nil; preselectCategory(); recordID = UUID() }
                    }
                    if let before = session.result {
                        Text("\(amount.isEmpty ? "0" : MoneyText.grouped(amount)) ₽")
                            .font(FolkiFont.money(amountSize)).monospacedDigit()
                            .foregroundStyle(money == nil ? Color.folkiTertiary : Color.folkiInk)
                            .lineLimit(1).minimumScaleFactor(0.3)
                            .frame(maxWidth: .infinity).padding(.horizontal, FolkiSpacing.page)
                            .contentTransition(reduceMotion ? .identity : .numericText()).animation(reduceMotion ? nil : FolkiMotion.quick, value: amount)
                            .accessibilityLabel("Сумма \(money.map(MoneyText.string) ?? "не введена")")
                        // One line of consequence: where the money comes from and what it leaves.
                        SpendConsequence(session: session, before: before, after: after, envelope: envelope, money: money,
                                         tint: scope == .personal ? Color.folkiPersonal : Color.folkiFamily)
                            .padding(.horizontal, FolkiSpacing.page)
                        if !isIncome { categoryIcons }
                        if isIncome {
                            Text("Поступление увеличит свободные деньги \(scope == .personal ? "личного" : "семейного") бюджета. Это не перевод из другого бюджета.")
                                .folkiText(.footnote).padding(.horizontal, FolkiSpacing.page)
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
                        Text(isIncome ? String(localized: "Внести деньги") : editing != nil ? String(localized: "Сохранить") : String(localized: "Записать")).font(FolkiFont.headline)
                            .frame(maxWidth: .infinity).frame(minHeight: FolkiSpacing.primaryButton)
                            .foregroundStyle(.white)
                            .glassEffect(.regular.tint(Color.folkiAccent.opacity(after == nil ? 0.35 : 1)).interactive(), in: Capsule())
                    }.buttonStyle(FolkiPressStyle()).disabled(after == nil)
                    .padding(.horizontal, FolkiSpacing.page).padding(.bottom, editing == nil ? FolkiSpacing.card : 0)
                    if let editing, let editingSession {
                        Button("Удалить трату", role: .destructive) { dismiss(); onDelete?(editing, editingSession) }
                            .font(FolkiFont.label).foregroundStyle(Color.folkiOver)
                            .frame(minHeight: 44).padding(.bottom, FolkiSpacing.xs)
                    }
                } }
            }
            .background { FolkiBackground() }
            .navigationTitle(editing.map { String(localized: "Трата · \($0.transaction.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))") }
                             ?? (isIncome ? String(localized: "Поступление") : String(localized: "Трата")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { FolkiCloseButton { dismiss() } }
            }
            .sheet(isPresented: $showingAllCategories) {
                CategoryGridSheet(session: session, selection: $categoryID, envelopeSelection: $envelopeID).presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $settingUp) { DailyFundingView(personal: personal, family: family, initialScope: scope) }
            .confirmationDialog(String(localized: "Это больше всех денег периода"), isPresented: $confirmingLarge, titleVisibility: .visible) {
                Button(String(localized: "Записать \(money.map(MoneyText.whole) ?? "")")) { largeConfirmed = true; save() }
                Button("Исправить сумму", role: .cancel) {}
            }
            .onAppear {
                if UserDefaults.standard.string(forKey: "FolkiLastSpendScope") == nil && family.hasFunding && !personal.hasFunding {
                    scopeRaw = BudgetScope.family.rawValue
                }
                prepareBudget()
                preselectCategory()
            }
            .onChange(of: activeScopeRaw) { prepareBudget() }
            .onChange(of: amount) { largeConfirmed = false }
        }
        .tint(Color.folkiAccent)
    }

    /// What the money is for, as round icons: the frequent categories, then the envelopes of their own (jars, bills
    /// in a category not shown) and "Ещё". Picking a category with a bill pays from that bill's envelope.
    private var categoryIcons: some View {
        let frequent = session.frequentCategories()
        let selected = categoryID.map { session.catalog.category(for: $0) }
        // A category picked under "Ещё" takes the third place for this spend.
        let categories = selected.map { frequent.contains($0) ? frequent : Array(frequent.prefix(2)) + [$0] } ?? frequent
        let shown = Set(categories.map(\.id))
        let envelopes = session.envelopes.filter { $0.isSavings || !shown.contains($0.categoryID ?? BuiltInCategory.other.id) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FolkiSpacing.item) {
                ForEach(categories) { category in
                    let isSelected = categoryID == category.id && (envelopeID == nil || envelope?.isSavings == false)
                    iconButton(isSelected: isSelected, color: category.color.color, label: category.name) {
                        CategoryIcon(category: category, size: chipHeight)
                    } action: {
                        envelopeID = nil; categoryID = isSelected ? nil : category.id
                    }
                }
                ForEach(envelopes) { item in
                    let isSelected = envelopeID == item.id
                    let category = session.catalog.category(for: item.categoryID ?? BuiltInCategory.other.id)
                    iconButton(isSelected: isSelected, color: (item.color ?? category.color).color, label: item.name) {
                        EnvelopeIcon(session: session, envelope: item, size: chipHeight)
                    } action: {
                        // A bill is reached through its category, so the category stays the one choice;
                        // a jar, or a bill filed under «Другое», is picked by itself.
                        let byCategory = !item.isSavings && (item.categoryID ?? BuiltInCategory.other.id) != BuiltInCategory.other.id
                        if isSelected { envelopeID = nil; categoryID = nil }
                        else if byCategory { envelopeID = nil; categoryID = item.categoryID }
                        else { envelopeID = item.id; categoryID = item.categoryID }
                    }
                }
                Button { showingAllCategories = true } label: {
                    Image(systemName: "ellipsis").font(FolkiFont.headline).foregroundStyle(Color.folkiSecondary)
                        .frame(width: chipHeight, height: chipHeight).background(Color.folkiTile, in: Circle()).padding(4)
                }
                .buttonStyle(FolkiPressStyle()).accessibilityLabel("Все категории")
            }
            .padding(.horizontal, FolkiSpacing.page).padding(.vertical, FolkiSpacing.xxs)
        }
    }

    private func iconButton<Icon: View>(isSelected: Bool, color: Color, label: String,
                                        @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button { action(); FolkiFeedback.selection() } label: {
            icon()
                .padding(4)
                .overlay { Circle().strokeBorder(color, lineWidth: isSelected ? 2.5 : 0) }
                .scaleEffect(isSelected ? 1.08 : 1)
                .animation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion), value: isSelected)
        }
        .buttonStyle(FolkiPressStyle())
        .accessibilityLabel(label).accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// More than all the money of the period: most likely an extra zero.
    private var looksMistyped: Bool {
        guard !isIncome, let money, let free = session.result?.monthlyRemaining else { return false }
        return money.minorUnits > max(free.minorUnits, 0) + (editing?.transaction.amount.minorUnits ?? 0)
    }

    private func save() {
        guard let draft else { return }
        if looksMistyped && !largeConfirmed { confirmingLarge = true; FolkiFeedback.boundary(); return }
        let crossed = !isIncome && FolkiFeedback.crossesIntoMinus(before: session.result?.todayRemaining, after: after?.todayRemaining)
        do {
            if let envelope, let money {
                // A bill is paid and moves to its next date; what the envelope lacks comes from living money.
                if envelope.isSavings {
                    try session.spendFromEnvelope(envelope, amount: money, operationID: recordID)
                } else {
                    try session.payEnvelope(envelope, amount: money, operationID: recordID)
                }
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
                    .font(FolkiFont.keypad)
                    .frame(maxWidth: .infinity, minHeight: keyHeight)
                    // Liquid glass, each key on its own: the keypad is never placed inside a GlassEffectContainer,
                    // so neighbouring keys do not melt into one another.
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: FolkiSpacing.card, style: .continuous))
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
                        Text("Конверты с деньгами").font(FolkiFont.headline)
                        Text("Если в конверте не хватит, разницу возьму из денег на жизнь.")
                            .folkiText(.footnote)
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
                                }.font(FolkiFont.caption).padding(.vertical, 8)
                            }.buttonStyle(.plain)
                        }
                        Divider()
                    }
                    // Without envelopes there is no source to choose: only categories, no explanations.
                    if !session.envelopes.isEmpty {
                        Text("На жизнь").font(FolkiFont.headline)
                        Text("Категория нужна только для статистики.")
                            .folkiText(.footnote)
                    }
                LazyVGrid(columns: columns, spacing: FolkiSpacing.page) {
                    ForEach(session.catalog.selectable) { category in
                        Button {
                            FolkiFeedback.selection(); envelopeSelection = nil; selection = category.id; dismiss()
                        } label: {
                            VStack(spacing: FolkiSpacing.xs) {
                                CategoryIcon(category: category, size: 52)
                                    .overlay { if envelopeSelection == nil && selection == category.id { Circle().strokeBorder(Color.folkiInk, lineWidth: 2).padding(-4) } }
                                Text(category.name).font(FolkiFont.footnote).foregroundStyle(Color.folkiInk)
                                    .lineLimit(2).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(FolkiPressStyle())
                    }
                    NavigationLink { CategoriesView(session: session) } label: {
                        VStack(spacing: FolkiSpacing.xs) {
                            Image(systemName: "plus").font(FolkiFont.section).foregroundStyle(Color.folkiAccent)
                                .frame(width: 52, height: 52).background(Color.folkiTile, in: Circle())
                            Text("Своя категория").font(FolkiFont.footnote).foregroundStyle(Color.folkiInk)
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

/// The one line under the amount: where the money comes from and what is left there.
/// Living money shows today before and after with what the next days get; an envelope shows its balance
/// before and after, and in red what living money has to add when the envelope is short.
struct SpendConsequence: View {
    let session: BudgetSession
    let before: DailyBudgetSnapshot
    let after: DailyBudgetSnapshot?
    let envelope: RecurringEnvelope?
    let money: Money?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let envelope { envelopeLine(envelope) } else { dayLine }
        }
        .padding(FolkiSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .folkiTileBackground()
        .animation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion), value: envelope?.id)
    }

    private var dayLine: some View {
        let result = after ?? before
        let over = result.todayRemaining.minorUnits < 0
        return HStack(spacing: FolkiSpacing.item) {
            Image(systemName: "wallet.bifold.fill").font(FolkiFont.label).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(tint, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                change(from: before.todayRemaining, to: money == nil ? nil : result.todayRemaining, over: over)
                bar(result.dayRingFraction, color: over ? Color.folkiOver : tint)
            }
            Spacer(minLength: FolkiSpacing.xs)
            if over {
                trailing(String(localized: "сверх"), MoneyText.whole(result.todayOverspending.roundedUpToWholeUnits), Color.folkiOver)
            } else if money != nil, let next = result.futureAllocation {
                trailing(String(localized: "дальше"), String(localized: "\(MoneyText.whole(next.firstDayAmount))/день"), Color.folkiSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func envelopeLine(_ envelope: RecurringEnvelope) -> some View {
        let balance = session.envelopeBalance(envelope)
        let spend = money?.minorUnits ?? 0
        let fromEnvelope = min(spend, max(0, balance.minorUnits))
        let left = Money(minorUnits: balance.minorUnits - fromEnvelope)
        let missing = spend - fromEnvelope
        let category = session.catalog.category(for: envelope.categoryID ?? BuiltInCategory.other.id)
        let color = (envelope.color ?? category.color).color
        return HStack(spacing: FolkiSpacing.item) {
            EnvelopeIcon(session: session, envelope: envelope, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                change(from: balance, to: money == nil ? nil : left, over: false)
                bar(Double(left.minorUnits) / Double(max(1, envelope.capacity.minorUnits)), color: color)
            }
            Spacer(minLength: FolkiSpacing.xs)
            if missing > 0 {
                trailing(String(localized: "с жизни"), "−\(MoneyText.whole(Money(minorUnits: missing)))", Color.folkiOver)
            } else if money != nil && !envelope.isSavings {
                Label("оплачено", systemImage: "checkmark.circle.fill").font(FolkiFont.label).foregroundStyle(Color.folkiAccent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "1 051 → 551": what there is now and, once an amount is typed, what stays.
    private func change(from: Money, to: Money?, over: Bool) -> some View {
        HStack(spacing: 6) {
            Text(MoneyText.whole(from)).foregroundStyle(to == nil ? Color.folkiInk : Color.folkiSecondary)
            if let to {
                Image(systemName: "arrow.forward").font(FolkiFont.tag).foregroundStyle(Color.folkiTertiary)
                Text(MoneyText.whole(to)).foregroundStyle(over ? Color.folkiOver : Color.folkiInk)
                    .contentTransition(.numericText(value: Double(to.minorUnits)))
            }
        }
        .font(FolkiFont.moneyRow).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
    }

    private func bar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule().fill(color).frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 6)
        .animation(FolkiMotion.resolved(FolkiMotion.ring, reduceMotion: reduceMotion), value: fraction)
    }

    private func trailing(_ caption: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(FolkiFont.moneySmall).monospacedDigit()
            Text(caption).font(FolkiFont.footnote)
        }
        .foregroundStyle(color).lineLimit(1)
    }
}
