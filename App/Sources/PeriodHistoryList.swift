import SwiftUI
import UIKit
import FolkiDuoCore

/// One record of either budget in the period history.
struct PeriodEntry: Identifiable, Equatable {
    let record: LedgerRecord
    let session: BudgetSession
    var id: String { session.scope.rawValue + record.id.uuidString }
    static func == (lhs: PeriodEntry, rhs: PeriodEntry) -> Bool { lhs.id == rhs.id && lhs.record.revision == rhs.record.revision }
}

/// "Траты за период" below the rings: both budgets in one list, days as inline headers with the day's total.
/// Own records open for editing; a long press deletes. Other people's records are read-only.
/// Lives inside the main screen's scroll view, so it does not scroll on its own.
struct PeriodHistoryList: View {
    let personal: BudgetSession
    let family: BudgetSession
    let edit: (PeriodEntry) -> Void
    let delete: (PeriodEntry) -> Void
    let cancelContribution: (PeriodEntry) -> Void

    enum Filter: Hashable { case all, personal, family }
    @State private var filter: Filter = .all
    /// The row whose swipe actions are showing; only one at a time.
    @State private var swiped: String?
    /// Past days opened to their full list; today is always open.
    @State private var expanded: Set<Date> = []

    private var hasFamily: Bool { family.household != nil }
    private var entries: [PeriodEntry] {
        let sessions: [BudgetSession] = switch filter {
        case .all: hasFamily ? [personal, family] : [personal]
        case .personal: [personal]
        case .family: [family]
        }
        // Spends and refunds only: top-ups, contributions and envelope moves are not spending.
        return sessions.flatMap { session in
            session.records.filter { [.expense, .refund].contains($0.transaction.kind) }.map { PeriodEntry(record: $0, session: session) }
        }
            .sorted { $0.record.transaction.date > $1.record.transaction.date }
    }
    private var days: [(Date, [PeriodEntry])] {
        let calendar = personal.calendar
        var order: [Date] = [], groups: [Date: [PeriodEntry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.record.transaction.date)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Section {
                if hasFamily {
                    FolkiSegmentedPicker(title: String(localized: "Показать"), selection: $filter,
                        options: [(String(localized: "Все"), .all), (String(localized: "Личные"), .personal), (String(localized: "Семейные"), .family)],
                        dots: [nil, Color.folkiPersonal, Color.folkiFamily]).padding(.bottom, FolkiSpacing.item)
                }
                if entries.isEmpty {
                    ContentUnavailableView("Трат пока нет", systemImage: "basket",
                        description: Text("Записанные траты появятся здесь")).padding(.top, FolkiSpacing.large)
                }
            } header: {
                Text("Траты за период").font(FolkiFont.section).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, FolkiSpacing.xs)
            }
            ForEach(days, id: \.0) { day, items in
                let today = personal.calendar.isDate(day, inSameDayAs: personal.referenceDate)
                let detailed = today || expanded.contains(day)
                // One rhythm for every day: header, 16, its spends; 32 to the next day, folded or not.
                VStack(alignment: .leading, spacing: FolkiSpacing.card) {
                    header(day, items, collapsible: !today, detailed: detailed)
                    if detailed {
                        VStack(spacing: 0) {
                            ForEach(items) { entry in
                                row(entry).padding(.vertical, FolkiSpacing.xxs)
                                if entry.id != items.last?.id { Divider().padding(.leading, 52) }
                            }
                        }
                        .padding(.horizontal, FolkiSpacing.card).padding(.vertical, FolkiSpacing.xxs)
                        .folkiTileBackground()
                        .transition(.opacity)
                    } else {
                        chips(items).transition(.opacity)
                    }
                }
                .padding(.bottom, FolkiSpacing.large)
            }
        }
        .animation(FolkiMotion.standard, value: entries)
    }

    /// What a day cost and what that meant: the day's ring, the total and a bar of categories against the plan.
    private func header(_ day: Date, _ items: [PeriodEntry], collapsible: Bool, detailed: Bool) -> some View {
        // The day's plan covers living money only; bills paid from envelopes were set aside before.
        let living = items.filter { $0.record.transaction.funding == .flexible }
        let spent = living.reduce(Int64(0)) { $0 + signedAmount($1) }
        let fromEnvelopes = items.reduce(Int64(0)) { $0 + signedAmount($1) } - spent
        let guide = dayGuide(day)
        let left = guide.map { $0 - spent }
        let over = (left ?? 0) < 0
        let today = !collapsible
        return Button {
            guard collapsible else { return }
            FolkiFeedback.selection()
            withAnimation(FolkiMotion.standard) { if detailed { expanded.remove(day) } else { expanded.insert(day) } }
        } label: {
            VStack(alignment: .leading, spacing: FolkiSpacing.item) {
                HStack(spacing: FolkiSpacing.item) {
                    if let guide { dayRing(spent: spent, guide: guide) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dayTitle(day)).font(FolkiFont.label).foregroundStyle(Color.folkiInk)
                        if let left {
                            Text(over ? String(localized: "+\(MoneyText.whole(Money(minorUnits: -left))) сверх")
                                 : today ? String(localized: "осталось \(MoneyText.whole(Money(minorUnits: left)))")
                                 : String(localized: "сэкономлено \(MoneyText.whole(Money(minorUnits: left)))"))
                                .font(FolkiFont.footnote).monospacedDigit().foregroundStyle(over ? Color.folkiOver : .secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MoneyText.whole(Money(minorUnits: max(0, spent))))
                            .font(FolkiFont.moneyCard).monospacedDigit().foregroundStyle(Color.folkiInk)
                            .contentTransition(.numericText(value: Double(spent)))
                        if fromEnvelopes > 0 {
                            Label(MoneyText.whole(Money(minorUnits: fromEnvelopes)), systemImage: "tray.full.fill")
                                .font(FolkiFont.footnote).monospacedDigit().foregroundStyle(Color.folkiSecondary)
                        }
                    }
                    if collapsible {
                        Image(systemName: "chevron.down").font(FolkiFont.tag).foregroundStyle(Color.folkiTertiary)
                            .rotationEffect(.degrees(detailed ? 180 : 0))
                    }
                }
                categoryBar(living, spent: spent, guide: guide)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(collapsible ? (detailed ? String(localized: "Свернуть день") : String(localized: "Показать все траты дня")) : "")
    }

    private func signedAmount(_ entry: PeriodEntry) -> Int64 {
        (entry.record.transaction.kind == .refund ? -1 : 1) * entry.record.transaction.amount.minorUnits
    }

    /// The plan the list is compared with: the budgets it shows, added up.
    private func dayGuide(_ day: Date) -> Int64? {
        let sessions: [BudgetSession] = switch filter {
        case .all: hasFamily ? [personal, family] : [personal]
        case .personal: [personal]
        case .family: [family]
        }
        let guides = sessions.compactMap { $0.overview(on: day).result?.todayGuide.minorUnits }
        return guides.isEmpty ? nil : guides.reduce(0, +)
    }

    private func dayRing(spent: Int64, guide: Int64) -> some View {
        let over = spent > guide
        let left = guide > 0 ? max(0, Double(guide - spent) / Double(guide)) : 0
        let tint = over ? Color.folkiOver : Color.folkiPersonal
        return ZStack {
            Circle().stroke(tint.opacity(over ? 0.25 : 0.2), lineWidth: 4)
            Circle().trim(from: 0, to: left).stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .frame(width: 30, height: 30).padding(2)
        .animation(FolkiMotion.ring, value: left)
        .accessibilityHidden(true)
    }

    /// Categories as coloured parts of the day's plan; what went over the plan is red at the end.
    private func categoryBar(_ items: [PeriodEntry], spent: Int64, guide: Int64?) -> some View {
        var totals: [(color: Color, amount: Int64)] = []
        var index: [UUID: Int] = [:]
        for entry in items {
            let id = entry.record.categoryID
            let amount = signedAmount(entry)
            if let at = index[id] { totals[at].amount += amount } else {
                index[id] = totals.count
                totals.append((entry.session.catalog.category(for: id).color.color, amount))
            }
        }
        let parts = totals.filter { $0.amount > 0 }.sorted { $0.amount > $1.amount }
        let plan = guide ?? spent
        let scale = Double(max(plan, spent, 1))
        let overflow = max(0, spent - plan)
        // Within the plan the categories share what was spent; past it they shrink to the plan and red takes the rest.
        let squeeze = overflow > 0 ? Double(plan) / Double(max(spent, 1)) : 1
        return GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Capsule().fill(part.color).frame(width: max(3, width * Double(part.amount) * squeeze / scale))
                }
                if overflow > 0 { Capsule().fill(Color.folkiOver).frame(width: max(3, width * Double(overflow) / scale)) }
                Spacer(minLength: 0)
            }
            .frame(width: width, height: 8, alignment: .leading)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    /// A past day folded: each spend as its icon and amount; a tap opens it.
    private func chips(_ items: [PeriodEntry]) -> some View {
        FlowLayout(spacing: FolkiSpacing.xs) {
            ForEach(items) { entry in
                let category = entry.session.category(for: entry.record)
                let amount = entry.record.transaction.amount
                Button {
                    if entry.session.isEditable(entry.record) { edit(entry) }
                } label: {
                    HStack(spacing: 6) {
                        if let category { CategoryIcon(category: category, size: 24) }
                        Text((entry.record.transaction.kind == .refund ? "+" : "") + MoneyText.whole(amount))
                            .font(FolkiFont.label).monospacedDigit().foregroundStyle(Color.folkiInk)
                    }
                    .padding(.leading, 4).padding(.trailing, FolkiSpacing.item).frame(minHeight: 32)
                    .background(Color.folkiTile, in: Capsule())
                }
                .buttonStyle(FolkiPressStyle())
                .accessibilityLabel("\(category?.name ?? String(localized: "Другое")), \(MoneyText.string(amount))")
            }
        }
    }

    @ViewBuilder private func row(_ entry: PeriodEntry) -> some View {
        let editable = entry.session.isEditable(entry.record)
        Group {
            if editable {
                SwipeActionsRow(id: entry.id, open: $swiped, edit: { edit(entry) }, delete: { delete(entry) }) {
                    Button { if swiped == nil { edit(entry) } else { withAnimation(FolkiMotion.quick) { swiped = nil } } } label: {
                        LedgerRow(record: entry.record, session: entry.session, showsDate: false)
                    }.buttonStyle(.plain)
                }
            } else {
                // Someone else's record shows who and when in its own line; nothing to change.
                LedgerRow(record: entry.record, session: entry.session, showsDate: false)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if entry.session.canCancelContribution(entry.record) {
                Button("Отменить взнос", systemImage: "arrow.uturn.backward", role: .destructive) { cancelContribution(entry) }
            } else if editable {
                Button("Изменить", systemImage: "pencil") { edit(entry) }
                Button("Удалить", systemImage: "trash", role: .destructive) { delete(entry) }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = personal.calendar
        if calendar.isDate(day, inSameDayAs: personal.referenceDate) { return String(localized: "Сегодня") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: personal.referenceDate),
           calendar.isDate(day, inSameDayAs: yesterday) { return String(localized: "Вчера") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// Snaps between the rings page and the start of the history; inside the history it scrolls freely.
struct RingsPageSnap: ScrollTargetBehavior {
    let page: CGFloat
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let start = context.originalTarget.rect.minY
        let end = target.rect.minY
        let threshold = min(180, max(100, page * 0.24))
        if start < page * 0.5 {
            // A deliberate drag crosses the page; a short movement springs back.
            target.rect.origin.y = end > threshold ? page : 0
        } else if start <= page + 32 && end < page {
            target.rect.origin.y = page - end > threshold ? 0 : page
        }
    }
}

/// Swipe left on one's own record to edit or delete it, like a list row. The context menu stays for a long press.
private struct SwipeActionsRow<Content: View>: View {
    let id: String
    @Binding var open: String?
    let edit: () -> Void
    let delete: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let width: CGFloat = 144
    private var offset: CGFloat { open == id ? min(0, -width + drag) : min(0, drag) }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                action(String(localized: "Изменить"), "pencil", Color.secondary) { close(); edit() }
                action(String(localized: "Удалить"), "trash", Color.folkiOver) { close(); delete() }
            }
            .opacity(offset < 0 ? 1 : 0)
            content()
                .offset(x: offset)
        }
        .clipped()
        // A UIKit pan that starts only on a sideways move, so the page above keeps scrolling vertically.
        .gesture(HorizontalPan { drag = $0 } ended: { translation in
            let shown = open == id ? translation < width / 2 : translation < -width / 2
            withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) {
                drag = 0
                if shown { open = id } else if open == id { open = nil }
            }
            if shown { FolkiFeedback.selection() }
        })
        .accessibilityAction(named: Text("Изменить"), edit)
        .accessibilityAction(named: Text("Удалить"), delete)
    }

    private func close() {
        withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) { open = nil }
    }

    private func action(_ title: String, _ symbol: String, _ tint: Color, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: FolkiSpacing.xxs) {
                Image(systemName: symbol).font(FolkiFont.headline)
                Text(title).font(FolkiFont.tag)
            }
            .foregroundStyle(.white)
            .frame(width: width / 2).frame(maxHeight: .infinity)
            .background(tint)
        }.buttonStyle(.plain)
    }
}

private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed: changed(x)
        case .ended, .cancelled, .failed: ended(x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

/// Chips in rows that wrap, left to right.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}
