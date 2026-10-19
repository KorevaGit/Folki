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
        .animation(reduceMotion ? nil : .snappy, value: result.todayRemaining)
    }

    @ViewBuilder private func today(_ remaining: Money) -> some View {
        if remaining.minorUnits < 0 {
            Text("Сегодня \(MoneyText.whole(remaining))").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
        } else {
            Text("\(after == nil ? "Сегодня можно" : "Сегодня останется") \(MoneyText.whole(remaining))").font(.subheadline)
        }
    }

    @ViewBuilder private func nextDays(_ result: DailyBudgetSnapshot) -> some View {
        if result.monthlyRemaining.minorUnits < 0 {
            Text("Месяц превышен на \(MoneyText.whole(Money(minorUnits: -result.monthlyRemaining.minorUnits).roundedUpToWholeUnits))")
                .font(.footnote).foregroundStyle(.red)
        } else if let future = result.futureAllocation {
            let change = after == nil ? nil : (try? result.nextDaysChange(since: before))
            let changeText = Text(change.map { " (\(signed($0)))" } ?? "")
                .foregroundStyle(change.map { $0.minorUnits < 0 } == true ? Color.red : .secondary)
            Text("Дальше в день: \(MoneyText.whole(future.firstDayAmount))\(changeText)").font(.footnote)
            Text("чтобы уложиться в месяц, \(future.days) дн.").font(.caption2).foregroundStyle(.secondary)
        } else {
            Text("Последний день месяца").font(.footnote).foregroundStyle(.secondary)
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
struct QuickSpendView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    let entryKind: TransactionKind
    @State private var incomeScopeRaw: String
    @AppStorage("FolkiLastSpendScope") private var scopeRaw = BudgetScope.personal.rawValue
    @State private var amount = ""
    @State private var categoryID: UUID?
    @State private var title = ""
    @FocusState private var descriptionFocused: Bool
    @State private var date: Date
    @State private var payerID: UUID?
    @State private var showingAllCategories = false
    @State private var settingUp = false
    @State private var recordID = UUID()
    @State private var errorMessage: String?
    @ScaledMetric(relativeTo: .body) private var chipHeight: CGFloat = 52

    init(personal: BudgetSession, family: BudgetSession, entryKind: TransactionKind = .expense, initialScope: BudgetScope = .personal) {
        self.personal = personal; self.family = family; self.entryKind = entryKind
        _incomeScopeRaw = State(initialValue: initialScope.rawValue)
        _date = State(initialValue: personal.referenceDate)
    }

    private var isIncome: Bool { entryKind == .income }
    private var activeScopeRaw: String { isIncome ? incomeScopeRaw : scopeRaw }
    private var scopeSelection: Binding<String> { isIncome ? $incomeScopeRaw : $scopeRaw }
    private var scope: BudgetScope { BudgetScope(rawValue: activeScopeRaw) ?? .personal }
    private var session: BudgetSession { scope == .personal ? personal : family }
    private var money: Money? {
        guard let money = try? Money(parsing: amount.hasSuffix(",") ? String(amount.dropLast()) : amount),
              money.minorUnits > 0 else { return nil }
        return money
    }
    private var draft: LedgerRecord? {
        guard let money, let payer = payerID ?? session.authorID else { return nil }
        return try? session.draft(amount: money, title: title, payerID: payer, date: date, kind: entryKind,
            categoryID: categoryID ?? BuiltInCategory.other.id, funding: .flexible, newRecordID: recordID)
    }
    private var after: DailyBudgetSnapshot? { draft.flatMap { try? session.preview($0) } }

    var body: some View {
        NavigationStack {
            FolkiEntryLayout(hidesKeypad: descriptionFocused) { availableHeight in
                SpendContentLayout(availableHeight: availableHeight) {
                    FolkiSegmentedPicker(title: "Бюджет", selection: scopeSelection,
                        options: BudgetScope.allCases.map { ($0.title, $0.rawValue) }, minimumHeight: 48)
                        .padding(.horizontal, FolkiSpacing.page)
                    .onChange(of: activeScopeRaw) { payerID = nil; categoryID = nil; recordID = UUID() }
                    if let before = session.result {
                        Text("\(amount.isEmpty ? "0" : amount) ₽")
                            .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(money == nil ? .tertiary : .primary)
                            .lineLimit(1).minimumScaleFactor(0.3)
                            .frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
                            .padding(.horizontal, FolkiSpacing.page)
                            .contentTransition(reduceMotion ? .identity : .numericText()).animation(reduceMotion ? nil : .snappy, value: amount)
                            .accessibilityLabel("Сумма \(money.map(MoneyText.string) ?? "не введена")")
                        ImpactLines(before: before, after: after)
                            .padding(.vertical, 12).padding(.horizontal, FolkiSpacing.card).frame(maxWidth: .infinity)
                            .folkiGlass(RoundedRectangle(cornerRadius: 18))
                            .padding(.horizontal, FolkiSpacing.page)
                        if !isIncome { categoryChips.frame(height: chipHeight + 12) }
                        if isIncome {
                            Text("Поступление увеличит свободные деньги \(scope == .personal ? "личного" : "семейного") бюджета. Это не перевод из другого бюджета.")
                                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, FolkiSpacing.page)
                        }
                        TextField("Описание · необязательно", text: $title)
                            .focused($descriptionFocused).submitLabel(.done)
                            .onSubmit { descriptionFocused = false }
                            .padding(FolkiSpacing.card).glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .padding(.horizontal, FolkiSpacing.page)
                        if let errorMessage {
                            FolkiErrorMessage(message: errorMessage).padding(.horizontal, FolkiSpacing.page)
                        }
                    } else {
                        ContentUnavailableView {
                            Label("\(scope.title) бюджет не настроен", systemImage: "wallet.bifold")
                        } description: {
                            Text("Укажи план на месяц, и Folki посчитает, сколько можно тратить в день.")
                        } actions: {
                            Button("Настроить") { settingUp = true }.buttonStyle(FolkiPrimaryButtonStyle())
                        }
                    }
                }
            } keypad: {
                if session.result != nil {
                    VStack(spacing: 12) {
                        AmountKeypad(text: $amount)
                        Button(action: save) {
                            Text(isIncome ? "Внести деньги" : "Записать").font(.system(.title3, design: .rounded, weight: .bold))
                                .frame(maxWidth: .infinity).frame(minHeight: 60)
                                .foregroundStyle(.white)
                                .glassEffect(.regular.tint(Color.folkiAccent.opacity(after == nil ? 0.35 : 1)).interactive(), in: Capsule())
                        }.buttonStyle(FolkiPressStyle()).disabled(after == nil)
                    }.padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
                }
            }
            .background { FolkiBackground() }
            .navigationTitle(isIncome ? "Внести" : "Потратить").toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { descriptionFocused = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }.tint(Color.folkiInk)
                }
            }
            .sheet(isPresented: $showingAllCategories) { CategoryPickerView(session: session, selection: $categoryID) }
            .sheet(isPresented: $settingUp) { BudgetSetupView(session: session) }
        }
        .tint(Color.folkiAccent)
    }

    private var categoryChips: some View {
        let frequent = session.frequentCategories()
        let selected = categoryID.map { session.catalog.category(for: $0) }
        let chips = frequent + (selected.map { frequent.contains($0) ? [] : [$0] } ?? [])
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { category in
                    let isSelected = categoryID == category.id
                    Button { categoryID = isSelected ? nil : category.id; FolkiFeedback.selection() } label: {
                        HStack(spacing: 6) {
                            CategoryIcon(category: category, size: 28)
                            Text(category.name).font(.subheadline).lineLimit(1)
                        }
                        .padding(.horizontal, FolkiSpacing.card).frame(minHeight: chipHeight)
                        .glassEffect(.regular.tint(isSelected ? category.color.color.opacity(0.3) : .clear).interactive(), in: Capsule())
                    }
                    .buttonStyle(FolkiPressStyle()).accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                Button("Ещё") { showingAllCategories = true }
                    .font(.subheadline.weight(.medium)).padding(.horizontal, 18).frame(minHeight: chipHeight)
                    .glassEffect(.regular.interactive(), in: Capsule()).buttonStyle(FolkiPressStyle())
            }.padding(.horizontal, FolkiSpacing.page)
        }
    }

    private func save() {
        guard let draft else { return }
        let overspends = !isIncome && after.map { $0.todayRemaining.minorUnits < 0 } == true
        do {
            try session.save(draft)
            FolkiFeedback.saved(overspending: overspends)
            dismiss()
        } catch {
            errorMessage = "Не удалось записать. Сумма осталась здесь, попробуй ещё раз."
        }
    }
}

/// Digits, one comma and up to two decimals; the system keyboard would cover the impact lines.
struct AmountKeypad: View {
    @Binding var text: String
    @ScaledMetric(relativeTo: .title2) private var keyHeight: CGFloat = 50
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
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(FolkiPressStyle(scale: 0.92))
                .accessibilityLabel(key == "⌫" ? "Стереть" : key == "," ? "Запятая" : key)
            }
        }
    }

    private func press(_ key: String) {
        let previous = text
        defer { text != previous ? FolkiFeedback.key() : FolkiFeedback.refused() }
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
