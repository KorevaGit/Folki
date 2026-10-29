import SwiftUI
import FolkiDuoCore

extension EnvelopeUrgency {
    /// Grey while calm, amber at 3–7 days, red at 0–2; accent once full.
    var color: Color {
        switch self {
        case .funded: Color.folkiAccent
        case .calm: Color.secondary
        case .attention: Color.folkiWarning
        case .serious: Color.folkiOver
        }
    }
}

/// Recurring payments of one budget, nearest first: summary, cards and an add button.
/// Lives inside the plan; the hosting stack provides `navigationDestination(for: RecurringEnvelope.self)`.
struct EnvelopesSection: View {
    let session: BudgetSession
    @Binding var creating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.item) {
            if session.envelopes.isEmpty {
                empty
            } else {
                if !session.payments.isEmpty { summary.padding(.bottom, FolkiSpacing.xs) }
                ForEach(sorted) { envelope in
                    NavigationLink(value: envelope) { EnvelopeCard(session: session, envelope: envelope) }
                        .buttonStyle(FolkiPressStyle(scale: 0.98))
                }
                if !session.jars.isEmpty {
                    Text("Копилки").font(FolkiFont.headline).padding(.top, FolkiSpacing.xs)
                    ForEach(session.jars) { jar in
                        NavigationLink(value: jar) { EnvelopeCard(session: session, envelope: jar) }
                            .buttonStyle(FolkiPressStyle(scale: 0.98))
                    }
                }
                Button { creating = true } label: {
                    Label("Добавить конверт", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(FolkiSoftButtonStyle())
            }
        }
    }

    /// Short envelopes first by date; full ones sink to the bottom.
    private var sorted: [RecurringEnvelope] {
        session.payments.sorted { lhs, rhs in
            let left = session.envelopeUrgency(lhs) == .funded, right = session.envelopeUrgency(rhs) == .funded
            return left != right ? !left : lhs.nextDue < rhs.nextDue
        }
    }

    /// The bills of this period: how much of them is set aside, and the period as a line with each bill on its day.
    /// Bills due after the period are only in the list; they do not count here yet.
    private var summary: some View {
        let open = session.periodBills.filter { !$0.done }.map(\.envelope)
        let saved = open.reduce(Int64(0)) { $0 + min(session.envelopeBalance($1).minorUnits, $1.size.minorUnits) }
        let total = open.reduce(Int64(0)) { $0 + $1.size.minorUnits }
        let missing = open.filter(\.isMandatory)
            .reduce(Int64(0)) { $0 + ((try? $1.shortfall(balance: session.envelopeBalance($1)).minorUnits) ?? 0) }
        let worst = open.map(session.envelopeUrgency).max() ?? .funded
        return VStack(alignment: .leading, spacing: FolkiSpacing.page) {
            if total > 0 {
                VStack(alignment: .leading, spacing: FolkiSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: FolkiSpacing.xs) {
                        Text(MoneyText.whole(Money(minorUnits: saved))).font(FolkiFont.moneyCard).monospacedDigit()
                            .contentTransition(.numericText()).animation(FolkiMotion.quick, value: saved)
                        Text("из \(MoneyText.whole(Money(minorUnits: total)))").font(FolkiFont.caption).foregroundStyle(Color.folkiSecondary).monospacedDigit()
                        Spacer(minLength: FolkiSpacing.xs)
                        if missing > 0 {
                            Text("−\(MoneyText.whole(Money(minorUnits: missing).roundedUpToWholeUnits))")
                                .font(FolkiFont.moneySmall).monospacedDigit()
                                .foregroundStyle(worst == .calm ? Color.folkiSecondary : worst.color)
                                .accessibilityLabel("Не хватает \(MoneyText.whole(Money(minorUnits: missing).roundedUpToWholeUnits))")
                        }
                    }
                    ProgressBar(fraction: Double(saved) / Double(total), color: worst == .funded ? .folkiAccent : worst.color, height: 6)
                }
            } else {
                Label("Платежи периода закрыты", systemImage: "checkmark.circle.fill")
                    .font(FolkiFont.label).foregroundStyle(Color.folkiAccent)
            }
            MonthLine(session: session)
        }
        .padding(FolkiSpacing.card)
        .folkiTileBackground()
    }

    private var empty: some View {
        VStack(spacing: FolkiSpacing.card) {
            Image(systemName: "tray.full").font(FolkiFont.symbol(40)).foregroundStyle(Color.folkiSecondary)
            Text("Аренда, интернет, подписки — отложу на них заранее, и они не съедят дневной бюджет")
                .folkiText(.caption).multilineTextAlignment(.center)
            Button("Добавить конверт") { creating = true }.buttonStyle(FolkiSoftButtonStyle())
        }.frame(maxWidth: .infinity).padding(.vertical, FolkiSpacing.large)
    }
}

/// The period as a ruler: one tick per day, a tall mark on today, each bill on its own day.
/// A bill still collecting money is a ring as big as its amount; a paid one shrinks to a small check,
/// so it never covers the days around it. The days gone are darker.
private struct MonthLine: View {
    let session: BudgetSession
    private let largest: CGFloat = 26
    private let smallest: CGFloat = 16
    private let paid: CGFloat = 16
    private let tag: CGFloat = 22
    private let tick: CGFloat = 6

    var body: some View {
        let bills = session.periodBills
        let calendar = session.calendar
        let start = calendar.startOfDay(for: session.household?.period.start ?? session.referenceDate)
        let end = session.household?.period.endExclusive ?? session.referenceDate.addingTimeInterval(30 * 86_400)
        let days = max(1, calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: end)).day ?? 30)
        let index = { (date: Date) in min(max(calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0, 0), days - 1) }
        let today = index(session.referenceDate)
        let biggest = Double(bills.map(\.envelope.size.minorUnits).max() ?? 1)
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        let baseline = tag + 8 + largest
        VStack(spacing: FolkiSpacing.xs) {
            GeometryReader { geometry in
                let cell = geometry.size.width / CGFloat(days)
                let x = { (day: Int) in cell * (CGFloat(day) + 0.5) }
                ZStack(alignment: .topLeading) {
                    ForEach(0..<days, id: \.self) { day in
                        // A longer tick every week from the start of the period.
                        let height = day % 7 == 0 ? tick + 4 : tick
                        Capsule().fill(day < today ? Color.folkiSecondary : Color.folkiSecondary.opacity(0.3))
                            .frame(width: 2, height: height)
                            .position(x: x(day), y: baseline + 4 + height / 2)
                    }
                    Capsule().fill(Color.folkiInk).frame(width: 3, height: baseline + 4 + tick + 4 - tag - 2)
                        .position(x: x(today), y: (tag + 2 + baseline + 4 + tick + 4) / 2)
                    ForEach(bills.filter(\.done), id: \.envelope.id) { bill in
                        check.position(x: x(index(bill.date)), y: baseline - paid / 2)
                            .accessibilityLabel("\(bill.envelope.name), \(bill.date.formatted(style)), оплачено")
                    }
                    ForEach(bills.filter { !$0.done }, id: \.envelope.id) { bill in
                        let side = smallest + (largest - smallest) * CGFloat((Double(bill.envelope.size.minorUnits) / biggest).squareRoot())
                        ring(day: calendar.component(.day, from: bill.date), side: side, color: tone(session.envelopeUrgency(bill.envelope)))
                            .position(x: x(index(bill.date)), y: baseline - side / 2)
                            .accessibilityLabel("\(bill.envelope.name), \(bill.date.formatted(style)), \(MoneyText.whole(bill.envelope.size))")
                    }
                    todayTag.position(x: min(max(x(today), 34), geometry.size.width - 34), y: tag / 2)
                }
            }
            .frame(height: baseline + 4 + tick + 4)
            HStack {
                Text(start.formatted(style)); Spacer(); Text(end.addingTimeInterval(-1).formatted(style))
            }
            .font(FolkiFont.footnote).monospacedDigit().foregroundStyle(Color.folkiTertiary)
        }
        .accessibilityElement(children: .contain)
    }

    private var check: some View {
        Image(systemName: "checkmark").font(FolkiFont.dot).foregroundStyle(.white)
            .frame(width: paid, height: paid).background(Color.folkiAccent, in: Circle())
            .background(Circle().fill(Color(uiColor: .systemBackground)).padding(-1.5))
    }

    private func ring(day: Int, side: CGFloat, color: Color) -> some View {
        ZStack {
            Circle().fill(Color(uiColor: .systemBackground))
            Circle().strokeBorder(color, lineWidth: 2)
            if side >= 20 { Text("\(day)").font(FolkiFont.dot).monospacedDigit().foregroundStyle(color) }
        }
        .frame(width: side, height: side)
        // A ring of the ground around each circle keeps neighbours and the today mark apart.
        .background(Circle().fill(Color(uiColor: .systemBackground)).padding(-1.5))
    }

    private var todayTag: some View {
        Text("сегодня").font(FolkiFont.tag).foregroundStyle(Color(uiColor: .systemBackground))
            .padding(.horizontal, FolkiSpacing.xs).frame(height: tag)
            .background(Color.folkiInk, in: Capsule())
            .fixedSize()
    }

    private func tone(_ urgency: EnvelopeUrgency) -> Color {
        urgency == .calm || urgency == .funded ? Color.folkiSecondary : urgency.color
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.folkiTile)
                Capsule().fill(color).frame(width: geo.size.width * (revealed ? max(0, min(1, fraction)) : 0))
            }
        }.frame(height: height).accessibilityHidden(true)
            .animation(reduceMotion ? nil : FolkiMotion.ring, value: revealed)
            .animation(reduceMotion ? nil : FolkiMotion.ring, value: fraction)
            .onAppear { revealed = true }
    }
}

/// Envelope icon: monochrome on this screen, colour belongs to the status.
/// A coloured circle with a white symbol, as lists in Reminders. Envelopes without their own icon use their category's.
struct EnvelopeIcon: View {
    let session: BudgetSession
    let envelope: RecurringEnvelope
    var size: CGFloat = 44
    var body: some View {
        let category = session.catalog.category(for: envelope.categoryID ?? BuiltInCategory.other.id)
        CategoryIcon(symbol: envelope.symbol ?? category.symbol, color: (envelope.color ?? category.color).color, size: size)
    }
}

/// Colour row and symbol groups for an envelope icon, with a big live preview.
struct IconPicker: View {
    @Binding var symbol: String
    @Binding var color: CategoryColor
    var body: some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.page) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: FolkiSpacing.item)], spacing: FolkiSpacing.item) {
                ForEach(CategoryColor.allCases) { item in
                    Button { FolkiFeedback.selection(); withAnimation(FolkiMotion.quick) { color = item } } label: {
                        Circle().fill(item.color).frame(width: 40, height: 40)
                            .overlay { if item == color { Circle().strokeBorder(.white, lineWidth: 3).padding(FolkiSpacing.xxs) } }
                    }.buttonStyle(FolkiPressStyle())
                        .accessibilityLabel(item.title).accessibilityAddTraits(item == color ? .isSelected : [])
                }
            }
            ForEach(CategorySymbols.groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: FolkiSpacing.xs) {
                    Text(group.0).font(FolkiFont.label).foregroundStyle(Color.folkiSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: FolkiSpacing.item)], spacing: FolkiSpacing.item) {
                        ForEach(group.1, id: \.self) { item in
                            Button { FolkiFeedback.selection(); withAnimation(FolkiMotion.quick) { symbol = item } } label: {
                                Image(systemName: item).font(FolkiFont.icon)
                                    .foregroundStyle(item == symbol ? .white : Color.folkiInk)
                                    .frame(width: 44, height: 44)
                                    .background(item == symbol ? color.color : Color.folkiTile, in: Circle())
                            }.buttonStyle(FolkiPressStyle())
                                .accessibilityLabel(CategorySymbols.title(for: item))
                                .accessibilityAddTraits(item == symbol ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }
}

/// "Значок": the picker in its own sheet, for envelopes made from a template.
struct IconPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var symbol: String
    @Binding var color: CategoryColor
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FolkiSpacing.page) {
                    CategoryIcon(symbol: symbol, color: color.color, size: 76)
                    IconPicker(symbol: $symbol, color: $color)
                }.padding(FolkiSpacing.page)
            }
            .navigationTitle("Значок").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

private struct EnvelopeCard: View {
    let session: BudgetSession
    let envelope: RecurringEnvelope
    var body: some View {
        let balance = session.envelopeBalance(envelope)
        let urgency = session.envelopeUrgency(envelope)
        VStack(spacing: FolkiSpacing.item) {
            HStack(spacing: FolkiSpacing.item) {
                EnvelopeIcon(session: session, envelope: envelope)
                VStack(alignment: .leading, spacing: FolkiSpacing.xxs) {
                    Text(envelope.name).font(FolkiFont.headline).foregroundStyle(Color.folkiInk).lineLimit(1)
                    Text(dueText(envelope, session: session)).font(FolkiFont.footnote)
                        .foregroundStyle(urgency == .funded || urgency == .calm ? .secondary : urgency.color)
                }
                Spacer(minLength: FolkiSpacing.xs)
                VStack(alignment: .trailing, spacing: FolkiSpacing.xxs) {
                    HStack(spacing: 4) {
                        if urgency == .funded { Image(systemName: "checkmark").font(FolkiFont.label).foregroundStyle(Color.folkiAccent) }
                        Text(MoneyText.whole(balance)).font(FolkiFont.moneyRow).monospacedDigit()
                            .contentTransition(.numericText()).animation(FolkiMotion.quick, value: balance)
                            .foregroundStyle(Color.folkiInk)
                    }
                    Text("из \(MoneyText.whole(envelope.capacity))").folkiText(.footnote).monospacedDigit()
                }
            }
            ProgressBar(fraction: Double(balance.minorUnits) / Double(envelope.capacity.minorUnits),
                        color: envelope.isSavings && urgency != .funded ? Color.folkiAccent : urgency.color)
        }
        .padding(FolkiSpacing.card)
        .folkiTileBackground()
        .accessibilityElement(children: .combine)
    }
}

@MainActor private func dueText(_ envelope: RecurringEnvelope, session: BudgetSession) -> String {
    if envelope.isSavings { return String(localized: "Копилка · по \(MoneyText.whole(envelope.size)) с поступления") }
    let date = envelope.nextDue.formatted(.dateTime.day().month(.abbreviated))
    let days = session.daysUntil(envelope)
    switch days {
    case ..<0: return String(localized: "\(date) · просрочен")
    case 0: return String(localized: "\(date) · сегодня")
    case 1: return String(localized: "\(date) · завтра")
    default: return String(localized: "\(date) · через \(days) дн.")
    }
}

/// One envelope: its ring, payments and the two actions.
struct EnvelopeDetailView: View {
    let session: BudgetSession
    let envelopeID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sheet: Sheet?
    @State private var paidCheck = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    enum Sheet: String, Identifiable { case fund, spend, edit; var id: String { rawValue } }
    private var envelope: RecurringEnvelope? { session.envelopes.first { $0.id == envelopeID } }

    var body: some View {
        ScrollView {
            if let envelope {
                let balance = session.envelopeBalance(envelope)
                let urgency = session.envelopeUrgency(envelope)
                VStack(spacing: FolkiSpacing.section) {
                    ZStack {
                        Circle().stroke(Color.folkiTile, lineWidth: 16)
                        Circle().trim(from: 0, to: Double(balance.minorUnits) / Double(envelope.capacity.minorUnits))
                            .stroke(urgency.color, style: StrokeStyle(lineWidth: 16, lineCap: .round)).rotationEffect(.degrees(-90))
                            .animation(FolkiMotion.ring, value: balance)
                        VStack(spacing: FolkiSpacing.xxs) {
                            Text(MoneyText.whole(balance)).font(FolkiFont.moneyLarge).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .contentTransition(.numericText()).animation(FolkiMotion.quick, value: balance)
                            Text("из \(MoneyText.whole(envelope.capacity))").folkiText(.caption)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }.padding(.horizontal, FolkiSpacing.large)
                        if paidCheck {
                            Image(systemName: "checkmark").font(FolkiFont.symbol(64, weight: .bold)).foregroundStyle(Color.folkiAccent)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }.frame(width: 200, height: 200).padding(.top, FolkiSpacing.page)
                    VStack(spacing: FolkiSpacing.xxs) {
                        EnvelopeIcon(session: session, envelope: envelope, size: 44).padding(.bottom, FolkiSpacing.xs)
                        Text(envelope.name).font(FolkiFont.section)
                        Text(envelope.isSavings ? dueText(envelope, session: session)
                             : String(localized: "Каждый месяц, \(envelope.dueDay)-го · \(dueText(envelope, session: session))"))
                            .folkiText(.caption)
                        if let through = envelope.closedThrough {
                            // Closed: the money is kept as it is until the period ends.
                            Label("Период закрыт · держу до \(through.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated)))",
                                  systemImage: "lock.fill")
                                .font(FolkiFont.label).foregroundStyle(Color.folkiAccent).padding(.top, FolkiSpacing.xxs)
                        }
                        if !envelope.isMandatory && !envelope.isSavings { Text("Необязательный").font(FolkiFont.footnote).foregroundStyle(Color.folkiTertiary) }
                    }.multilineTextAlignment(.center)
                    actions
                    if !envelope.isSavings && session.daysUntil(envelope) < 0 {
                        // A missed bill does not stay red forever.
                        Button("Не платил — перенести на следующий раз", systemImage: "calendar.badge.clock") { skip(envelope) }
                            .buttonStyle(FolkiSoftButtonStyle())
                    }
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                    history(envelope)
                }.folkiPagePadding()
            }
        }
        .background { FolkiBackground() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Изменить", systemImage: "pencil") { sheet = .edit }
                    Button("Удалить конверт", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Ещё")
            }
        }
        .sheet(item: $sheet) { kind in
            if let envelope {
                switch kind {
                case .fund: EnvelopeAmountSheet(session: session, envelope: envelope, mode: .fund) { _ in }
                case .spend: EnvelopeAmountSheet(session: session, envelope: envelope, mode: .spend) { _ in }
                case .edit: EnvelopeEditorView(session: session, editing: envelope)
                }
            }
        }
        .confirmationDialog("Удалить конверт?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive, action: archive)
        } message: {
            Text("Деньги из него вернутся на жизнь, история сохранится")
        }
    }

    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return GlassEffectContainer(spacing: 12) {
            layout {
                Button(action: primaryAction) {
                    Text(envelope?.isSavings == true ? String(localized: "Потратить")
                         : envelope?.isClosed == true ? String(localized: "Открыть снова") : String(localized: "Закрыть период"))
                        .frame(maxWidth: .infinity, minHeight: FolkiSpacing.primaryButton)
                        .foregroundStyle(.white)
                        .glassEffect(.regular.tint(Color.folkiAccent).interactive(), in: Capsule())
                }
                .buttonStyle(FolkiPressStyle())
                .frame(minWidth: 104, maxWidth: .infinity)
                // A closed envelope asks for nothing until the period ends.
                if envelope?.isClosed != true {
                Button { sheet = .fund } label: {
                    Text("+ Пополнить")
                        .frame(maxWidth: .infinity, minHeight: FolkiSpacing.primaryButton)
                        .foregroundStyle(Color.folkiInk)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(FolkiPressStyle())
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 140)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                }
            }
            .font(FolkiFont.moneyCard)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(0.8)
        }
    }

    private func history(_ envelope: RecurringEnvelope) -> some View {
        let records = session.envelopeHistory(envelope)
        return VStack(alignment: .leading, spacing: 0) {
            if !records.isEmpty {
                Text("История").font(FolkiFont.headline).padding(.bottom, FolkiSpacing.xs)
                ForEach(records) { record in
                    let paid = record.transaction.kind == .expense
                    let released = record.transaction.kind == .reserveRelease
                    HStack {
                        Text(paid ? "Потрачено" : released ? "Вернулось на жизнь" : "Пополнение").font(FolkiFont.body)
                        Spacer()
                        Text("\(paid || released ? "−" : "+")\(MoneyText.whole(record.transaction.amount))")
                            .font(FolkiFont.moneyRow).monospacedDigit()
                        Text(record.transaction.date, format: .dateTime.day().month(.abbreviated))
                            .folkiText(.footnote).frame(width: 64, alignment: .trailing)
                    }.frame(minHeight: 44)
                    Divider()
                }
            }
        }
    }

    /// A jar is spent from; a bill is closed for this time, or opened again if it was closed by mistake.
    private func primaryAction() {
        guard let envelope else { return }
        if envelope.isSavings { sheet = .spend; return }
        do {
            if envelope.isClosed {
                try session.reopenEnvelope(envelope)
            } else {
                try session.closeEnvelope(envelope)
                FolkiFeedback.saved()
                withAnimation(FolkiMotion.quick) { paidCheck = true }
                Task {
                    try? await Task.sleep(for: .seconds(0.8))
                    withAnimation(FolkiMotion.standard) { paidCheck = false }
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Не получилось закрыть период. Попробуй ещё раз.")
        }
    }

    private func skip(_ envelope: RecurringEnvelope) {
        do { try session.skipEnvelope(envelope); errorMessage = nil }
        catch { errorMessage = String(localized: "Не получилось перенести платёж. Попробуй ещё раз.") }
    }

    private func archive() {
        guard let envelope else { return }
        do { try session.archiveEnvelope(envelope); dismiss() }
        catch { errorMessage = String(localized: "Не получилось удалить конверт. Попробуй ещё раз.") }
    }
}

/// Amount sheet for "Пополнить" (from living money) and "Потратить" (from the envelope).
private struct EnvelopeAmountSheet: View {
    enum Mode { case fund, spend }
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    let envelope: RecurringEnvelope
    let mode: Mode
    let done: (Money) -> Void
    @State private var amount = ""
    @State private var operationID = UUID()
    @State private var errorMessage: String?
    private var money: Money? { (try? MoneyText.parse(amount)).flatMap { $0.minorUnits > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            VStack(spacing: FolkiSpacing.page) {
                Text(mode == .spend ? "Сколько взять из «\(envelope.name)»?" : "Сколько положить в «\(envelope.name)»?")
                    .font(FolkiFont.headline).multilineTextAlignment(.center)
                Text("\(amount.isEmpty ? "0" : MoneyText.grouped(amount)) ₽")
                    .font(FolkiFont.money(FolkiFont.inputSize)).monospacedDigit()
                    .foregroundStyle(money == nil ? .tertiary : .primary).lineLimit(1).minimumScaleFactor(0.4)
                    .contentTransition(.numericText()).animation(FolkiMotion.quick, value: amount)
                Text(hint).folkiText(.footnote).multilineTextAlignment(.center)
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                Spacer(minLength: 0)
                AmountKeypad(text: $amount)
                Button(mode == .spend ? "Потратить" : "Положить", action: save)
                    .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            }
            .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.xs).padding(.top, FolkiSpacing.page)
            .toolbar { ToolbarItem(placement: .cancellationAction) { FolkiCloseButton { dismiss() } } }
        }
        .onAppear {
            let need = (try? envelope.shortfall(balance: session.envelopeBalance(envelope))) ?? envelope.size
            let free = session.result?.monthlyRemaining.nonnegative ?? Money(minorUnits: 0)
            let start = switch mode {
            case .spend: Money(minorUnits: 0)
            case .fund: Money(minorUnits: min(need.minorUnits, free.minorUnits))
            }
            amount = start.minorUnits > 0 ? MoneyText.input(start) : ""
        }
        .presentationDetents([.large])
    }

    private var hint: String {
        let balance = session.envelopeBalance(envelope)
        guard let money else { return "" }
        switch mode {
        case .fund:
            return String(localized: "Из денег на жизнь")
        case .spend:
            if money.minorUnits > balance.minorUnits {
                return String(localized: "\(MoneyText.whole(Money(minorUnits: money.minorUnits - balance.minorUnits))) доложу с жизни — по дням, не сегодня")
            }
            return String(localized: "В конверте останется \(MoneyText.whole(Money(minorUnits: balance.minorUnits - money.minorUnits)))")
        }
    }

    private func save() {
        guard let money else { FolkiFeedback.boundary(); return }
        do {
            switch mode {
            case .fund: try session.fundEnvelope(envelope, amount: money, operationID: operationID)
            case .spend: try session.spendFromEnvelope(envelope, amount: money, operationID: operationID)
            }
            FolkiFeedback.saved()
            dismiss()
            done(money)
        } catch BudgetError.insufficientReserve {
            errorMessage = String(localized: "Столько свободных денег сейчас нет")
        } catch {
            errorMessage = String(localized: "Не получилось сохранить. Попробуй ещё раз.")
        }
    }
}

/// Create or edit an envelope in three short steps: what, how much a month, which day.
struct EnvelopeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: BudgetSession
    var editing: RecurringEnvelope?
    /// Creating an envelope never moves living money; funding is a separate action.
    var onCreated: ((RecurringEnvelope) -> Void)? = nil

    enum Step: Int { case what, amount, day }
    @State private var step: Step = .what
    @State private var forward = true
    @State private var custom = false
    @State private var name = ""
    @State private var categoryID: UUID?
    @State private var symbol = "tag.fill"
    @State private var color: CategoryColor = .blue
    @State private var pickingIcon = false
    @State private var amount = ""
    @State private var day = 0
    @State private var mandatory = true
    @State private var fundNow = false
    /// Jars only: the goal, typed on the last step instead of a payment day.
    @State private var goal = ""
    @State private var draftID = UUID()
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool
    private var money: Money? { (try? MoneyText.parse(amount)).flatMap { $0.minorUnits > 0 ? $0 : nil } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isJar: Bool { editing?.isSavings == true }
    private var goalMoney: Money? { (try? MoneyText.parse(goal)).flatMap { $0.minorUnits > 0 ? $0 : nil } }
    private var calendar: Calendar { session.calendar }
    private var firstDue: Date? {
        guard day > 0 else { return nil }
        if let editing, editing.dueDay == day { return editing.nextDue }
        return try? EnvelopeSchedule.firstDue(day: day, onOrAfter: session.referenceDate, calendar: calendar)
    }

    private var recommended: Money {
        guard editing == nil, let money, let firstDue,
              let candidate = try? RecurringEnvelope(id: draftID, name: trimmedName, size: money,
                dueDay: day, nextDue: firstDue, isMandatory: mandatory, categoryID: categoryID) else { return Money(minorUnits: 0) }
        return session.recommendedFunding(for: candidate)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress.padding(.top, FolkiSpacing.xs)
                ZStack {
                    page.id(step).transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }.frame(maxHeight: .infinity).clipped()
            }
            .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.xs)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .what {
                        FolkiCloseButton {
                            if custom && editing == nil {
                                nameFocused = false
                                name = ""; categoryID = nil; symbol = "tag.fill"; color = .blue
                                amount = ""; day = 0; mandatory = true
                                errorMessage = nil
                                withAnimation(FolkiMotion.quick) { custom = false }
                            } else { dismiss() }
                        }
                    }
                    else { Button("Назад", systemImage: "chevron.left") { go(Step(rawValue: step.rawValue - 1)!, forward: false) } }
                }
            }
        }
        .onAppear(perform: load)
    }

    private var progress: some View {
        HStack(spacing: FolkiSpacing.xs) {
            ForEach(0..<3) { index in
                Capsule().fill(index <= step.rawValue ? Color.folkiAccent : Color.folkiTile).frame(height: 4)
            }
        }.animation(FolkiMotion.quick, value: step).accessibilityHidden(true)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .what: whatPage
        case .amount: amountPage
        case .day: if isJar { goalPage } else { dayPage }
        }
    }

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text).font(FolkiFont.title).frame(maxWidth: .infinity, alignment: .leading).padding(.top, FolkiSpacing.page)
    }

    private var whatPage: some View {
        VStack(spacing: FolkiSpacing.page) {
            title(editing == nil ? "Что откладываем?" : "Название")
            if custom || editing != nil {
                ScrollView {
                    VStack(spacing: FolkiSpacing.page) {
                        HStack(spacing: FolkiSpacing.item) {
                            CategoryIcon(symbol: symbol, color: color.color, size: 56)
                            TextField("Например, аренда", text: $name)
                                .font(FolkiFont.headline).focused($nameFocused).submitLabel(.next)
                                .onSubmit(nextFromWhat)
                        }
                        .padding(FolkiSpacing.item)
                        .folkiTileBackground()
                        IconPicker(symbol: $symbol, color: $color)
                    }.padding(.bottom, FolkiSpacing.page)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { if editing == nil { nameFocused = true } }
                Button("Дальше", action: nextFromWhat).buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
                    .disabled(trimmedName.isEmpty)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FolkiSpacing.xs), count: 3), spacing: FolkiSpacing.page) {
                        ForEach(PaymentTemplates.all) { category in
                            Button {
                                FolkiFeedback.selection()
                                name = category.name; categoryID = category.id; mandatory = category.isEssential
                                symbol = category.symbol; color = category.color
                                go(.amount)
                            } label: {
                                VStack(spacing: FolkiSpacing.xs) {
                                    CategoryIcon(category: category, size: 52)
                                    Text(category.name).font(FolkiFont.footnote).foregroundStyle(Color.folkiInk)
                                        .lineLimit(2).multilineTextAlignment(.center)
                                }.frame(maxWidth: .infinity)
                            }.buttonStyle(FolkiPressStyle())
                        }
                        Button {
                            FolkiFeedback.selection(); name = ""; categoryID = nil; symbol = "tag.fill"; color = .blue
                            withAnimation(FolkiMotion.quick) { custom = true }
                        } label: {
                            VStack(spacing: FolkiSpacing.xs) {
                                Image(systemName: "plus").font(FolkiFont.section).foregroundStyle(Color.folkiAccent)
                                    .frame(width: 52, height: 52).background(Color.folkiTile, in: Circle())
                                Text("Свой").font(FolkiFont.footnote).foregroundStyle(Color.folkiInk)
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(FolkiPressStyle())
                    }.padding(.vertical, FolkiSpacing.xs)
                }.scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var amountPage: some View {
        VStack(spacing: FolkiSpacing.page) {
            title(isJar ? "Сколько откладывать с поступления?" : "Сколько планируем отложить?")
            Button { pickingIcon = true } label: {
                HStack(spacing: FolkiSpacing.xs) {
                    CategoryIcon(symbol: symbol, color: color.color, size: 36)
                    Text(trimmedName).font(FolkiFont.headline).foregroundStyle(Color.folkiInk)
                    Image(systemName: "pencil").font(FolkiFont.label).foregroundStyle(Color.folkiSecondary)
                }
            }
            .buttonStyle(FolkiPressStyle()).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHint("Изменить значок")
            .sheet(isPresented: $pickingIcon) { IconPickerSheet(symbol: $symbol, color: $color).presentationDetents([.large]) }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TypedAmount(text: amount)
                Text("₽").foregroundStyle(Color.folkiSecondary)
            }
            .font(FolkiFont.money(FolkiFont.inputSize))
            .foregroundStyle(money == nil ? Color.secondary : color.color)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            AmountKeypad(text: $amount)
            Button("Дальше") {
                guard money != nil else { FolkiFeedback.boundary(); return }
                go(.day)
            }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        }
    }

    private var goalPage: some View {
        VStack(spacing: FolkiSpacing.page) {
            title("Сколько хочешь накопить?")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TypedAmount(text: goal)
                Text("₽").foregroundStyle(Color.folkiSecondary)
            }
            .font(FolkiFont.money(FolkiFont.inputSize))
            .foregroundStyle(goalMoney == nil ? Color.secondary : color.color)
            .frame(maxWidth: .infinity)
            if let money, let goalMoney {
                Text("Пополнений до цели: \(max(1, Int((goalMoney.minorUnits + money.minorUnits - 1) / money.minorUnits)))")
                    .folkiText(.caption)
            }
            if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            Spacer(minLength: 0)
            AmountKeypad(text: $goal)
            Button("Сохранить", action: save).buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(goalMoney == nil)
        }
    }

    private var dayPage: some View {
        VStack(spacing: FolkiSpacing.item) {
            ScrollView {
                VStack(spacing: FolkiSpacing.page) {
            title("Какого числа платёж?")
            // The same wheel as in the plan setup.
            Picker("День оплаты", selection: Binding(get: { day == 0 ? 25 : day }, set: { day = $0 })) {
                ForEach(1...31, id: \.self) { Text("\($0)-го").tag($0) }
            }
            .pickerStyle(.wheel).frame(height: 150)
            .sensoryFeedback(.selection, trigger: day)
            .onAppear { if day == 0 { day = 25 } }
            Group {
                if let firstDue {
                    Text("Ближайший платёж — \(firstDue.formatted(.dateTime.day().month(.wide)))")
                } else {
                    Text("Каждый месяц")
                }
            }
            .folkiText(.caption).frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: $mandatory) {
                Text("Обязательный")
            }
            .padding(FolkiSpacing.card)
            .folkiTileBackground()
            if editing == nil, day > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Рекомендую сейчас: \(MoneyText.whole(recommended))").font(FolkiFont.headline)
                    if recommended.minorUnits > 0 {
                        Toggle("Пополнить при создании", isOn: $fundNow)
                        let free = session.result?.monthlyRemaining.minorUnits ?? 0
                        Text("На жизнь останется \(MoneyText.whole(Money(minorUnits: max(0, free - (fundNow ? recommended.minorUnits : 0)))))")
                            .folkiText(.footnote)
                    } else {
                        Text("Пополню со следующего поступления")
                            .folkiText(.footnote)
                    }
                }
                .padding(FolkiSpacing.card).folkiGlassBackground()
            }
            if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                }.padding(.bottom, FolkiSpacing.item)
            }.scrollBounceBehavior(.basedOnSize)
            Button(editing == nil ? "Создать" : "Сохранить", action: save)
                .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(day == 0)
        }
    }

    private func nextFromWhat() {
        guard !trimmedName.isEmpty else { FolkiFeedback.boundary(); return }
        nameFocused = false
        go(.amount)
    }

    private func go(_ next: Step, forward: Bool = true) {
        self.forward = forward
        withAnimation(FolkiMotion.resolved(FolkiMotion.standard, reduceMotion: reduceMotion)) { step = next }
    }

    private func load() {
        guard let editing else { return }
        name = editing.name; categoryID = editing.categoryID
        let category = session.catalog.category(for: editing.categoryID ?? BuiltInCategory.other.id)
        symbol = editing.symbol ?? category.symbol; color = editing.color ?? category.color
        amount = MoneyText.input(editing.size); day = editing.dueDay; mandatory = editing.isMandatory
        goal = editing.target.map(MoneyText.input) ?? ""
    }

    private func save() {
        guard let money, !trimmedName.isEmpty, let firstDue else { FolkiFeedback.boundary(); return }
        do {
            if let editing {
                guard !isJar || goalMoney != nil else { FolkiFeedback.boundary(); return }
                try session.updateEnvelope(editing.with(name: trimmedName, size: money, dueDay: day,
                                                        nextDue: firstDue, isMandatory: mandatory, symbol: symbol, color: color,
                                                        target: isJar ? goalMoney : nil))
                FolkiFeedback.saved(); dismiss()
            } else {
                let created = try session.createEnvelope(name: trimmedName, size: money, nextDue: firstDue,
                                                         isMandatory: mandatory, categoryID: categoryID, symbol: symbol, color: color,
                                                         id: draftID, initialFunding: fundNow ? recommended : Money(minorUnits: 0))
                FolkiFeedback.saved()
                onCreated?(created)
                dismiss()
            }
        } catch {
            errorMessage = String(localized: "Не получилось сохранить конверт. Попробуй ещё раз.")
        }
    }


}

/// The thirteen built-in categories, with a separate custom-envelope action.
@MainActor enum PaymentTemplates {
    static let all = BuiltInCategory.allCases.filter { $0 != .other }.map(\.category)
}
