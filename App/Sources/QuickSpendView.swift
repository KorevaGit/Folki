import SwiftUI
import UIKit
import FolkiDuoCore

/// What an operation does to a budget: today's remainder and the daily amount for the rest of the month.
struct ImpactLines: View {
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
        .animation(.snappy, value: result.todayRemaining)
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
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @AppStorage("FolkiLastSpendScope") private var scopeRaw = BudgetScope.personal.rawValue
    @State private var amount = ""
    @State private var categoryID: UUID?
    @State private var title = ""
    @State private var date: Date
    @State private var payerID: UUID?
    @State private var showingDetails = false
    @State private var showingAllCategories = false
    @State private var settingUp = false
    @State private var recordID = UUID()
    @State private var errorMessage: String?

    init(personal: BudgetSession, family: BudgetSession) {
        self.personal = personal; self.family = family
        _date = State(initialValue: personal.referenceDate)
    }

    private var scope: BudgetScope { BudgetScope(rawValue: scopeRaw) ?? .personal }
    private var session: BudgetSession { scope == .personal ? personal : family }
    private var money: Money? {
        guard let money = try? Money(parsing: amount.hasSuffix(",") ? String(amount.dropLast()) : amount),
              money.minorUnits > 0 else { return nil }
        return money
    }
    private var draft: LedgerRecord? {
        guard let money, let payer = payerID ?? session.authorID else { return nil }
        return try? session.draft(amount: money, title: title, payerID: payer, date: date, kind: .expense,
            categoryID: categoryID ?? BuiltInCategory.other.id, funding: .flexible, newRecordID: recordID)
    }
    private var after: DailyBudgetSnapshot? { draft.flatMap { try? session.preview($0) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Picker("Бюджет", selection: $scopeRaw) {
                    ForEach(BudgetScope.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).padding(.horizontal)
                .onChange(of: scopeRaw) { payerID = nil; categoryID = nil; recordID = UUID() }
                if let before = session.result {
                    Text("\(amount.isEmpty ? "0" : amount) ₽")
                        .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(money == nil ? .tertiary : .primary)
                        .lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal)
                        .contentTransition(.numericText()).animation(.snappy, value: amount)
                        .accessibilityLabel("Сумма \(money.map(MoneyText.string) ?? "не введена")")
                    ImpactLines(before: before, after: after)
                    categoryChips
                    TextField("Описание · необязательно", text: $title)
                        .textFieldStyle(.roundedBorder).padding(.horizontal)
                    detailsLine
                    Spacer(minLength: 0)
                    AmountKeypad(text: $amount).padding(.horizontal)
                    Button(action: save) {
                        Text("Записать").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal)
                    .disabled(after == nil)
                    if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red).padding(.horizontal) }
                } else {
                    ContentUnavailableView {
                        Label("\(scope.title) бюджет не настроен", systemImage: "wallet.bifold")
                    } description: {
                        Text("Укажи план на месяц, и Folki посчитает, сколько можно тратить в день.")
                    } actions: {
                        Button("Настроить") { settingUp = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.top, 8).padding(.bottom, 12)
            .navigationTitle("Трата").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .sheet(isPresented: $showingAllCategories) { CategoryPickerView(session: session, selection: $categoryID) }
            .sheet(isPresented: $settingUp) { BudgetSetupView(session: session) }
        }
    }

    private var categoryChips: some View {
        let frequent = session.frequentCategories()
        let selected = categoryID.map { session.catalog.category(for: $0) }
        let chips = frequent + (selected.map { frequent.contains($0) ? [] : [$0] } ?? [])
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { category in
                    let isSelected = categoryID == category.id
                    Button { categoryID = isSelected ? nil : category.id } label: {
                        HStack(spacing: 6) {
                            CategoryIcon(category: category, size: 22)
                            Text(category.name).font(.subheadline).lineLimit(1)
                        }
                        .padding(.leading, 5).padding(.trailing, 12).padding(.vertical, 5)
                        .background(isSelected ? category.color.color.opacity(0.22) : Color(uiColor: .tertiarySystemFill), in: Capsule())
                        .overlay { if isSelected { Capsule().stroke(category.color.color, lineWidth: 1.5) } }
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                Button("Ещё") { showingAllCategories = true }
                    .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule()).buttonStyle(.plain)
            }.padding(.horizontal)
        }
    }

    @ViewBuilder private var detailsLine: some View {
        let isToday = session.calendar.isDate(date, inSameDayAs: session.referenceDate)
        let payer = payerID ?? session.authorID
        Button { withAnimation(.snappy) { showingDetails.toggle() } } label: {
            Text("\(isToday ? "Сегодня" : date.formatted(.dateTime.day().month())) · оплатил \(payer.map(session.memberName) ?? "—") · \(showingDetails ? "скрыть" : "изменить")")
                .font(.footnote).foregroundStyle(.secondary)
        }.buttonStyle(.plain)
        if showingDetails, let budget = session.storedBudget {
            VStack(spacing: 8) {
                DatePicker("Дата", selection: $date, in: budget.snapshot.period.start...session.calculationDate(in: budget), displayedComponents: .date)
                if session.members.filter(\.isActive).count > 1 {
                    Picker("Оплатил", selection: Binding(get: { payerID ?? session.authorID ?? UUID() }, set: { payerID = $0 })) {
                        ForEach(session.members.filter(\.isActive)) { Text(session.memberName($0.id)).tag($0.id) }
                    }
                }
            }.font(.subheadline).padding(.horizontal)
        }
    }

    private func save() {
        guard let draft else { return }
        let overspends = after.map { $0.todayRemaining.minorUnits < 0 } == true
        do {
            try session.save(draft)
            if overspends { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            else { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            dismiss()
        } catch {
            errorMessage = "Не удалось записать. Сумма осталась здесь, попробуй ещё раз."
        }
    }
}

/// Digits, one comma and up to two decimals; the system keyboard would cover the impact lines.
struct AmountKeypad: View {
    @Binding var text: String
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ",", "0", "⌫"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(keys, id: \.self) { key in
                Button { press(key) } label: {
                    Group {
                        if key == "⌫" { Image(systemName: "delete.left") } else { Text(key) }
                    }
                    .font(.system(.title2, design: .rounded, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key == "⌫" ? "Стереть" : key == "," ? "Запятая" : key)
            }
        }
    }

    private func press(_ key: String) {
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
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
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
