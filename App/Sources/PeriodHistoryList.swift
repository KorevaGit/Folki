import SwiftUI
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

    private var hasFamily: Bool { family.household != nil }
    private var entries: [PeriodEntry] {
        let sessions: [BudgetSession] = switch filter {
        case .all: hasFamily ? [personal, family] : [personal]
        case .personal: [personal]
        case .family: [family]
        }
        return sessions.flatMap { session in session.records.map { PeriodEntry(record: $0, session: session) } }
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
                        minimumHeight: 36).padding(.bottom, FolkiSpacing.item)
                }
                if entries.isEmpty {
                    ContentUnavailableView("Трат пока нет", systemImage: "basket",
                        description: Text("Записанные траты появятся здесь")).padding(.top, FolkiSpacing.large)
                }
            } header: {
                Text("Траты за период").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, FolkiSpacing.xs)
            }
            ForEach(days, id: \.0) { day, items in
                Section {
                    VStack(spacing: 0) {
                        ForEach(items) { entry in
                            row(entry)
                            if entry.id != items.last?.id { Divider().padding(.leading, 52) }
                        }
                    }
                    .padding(.horizontal, FolkiSpacing.card)
                    .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
                    .padding(.bottom, FolkiSpacing.page)
                } header: { header(day, items) }
            }
        }
        .animation(FolkiMotion.standard, value: entries)
    }

    private func header(_ day: Date, _ items: [PeriodEntry]) -> some View {
        let spent = items.filter { $0.record.transaction.kind == .expense }.reduce(Int64(0)) { $0 + $1.record.transaction.amount.minorUnits }
        return HStack {
            Text(dayTitle(day)).font(.subheadline.weight(.semibold))
            Spacer()
            if spent > 0 { Text("−\(MoneyText.whole(Money(minorUnits: spent)))").font(.subheadline).monospacedDigit() }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, FolkiSpacing.xs)
    }

    @ViewBuilder private func row(_ entry: PeriodEntry) -> some View {
        let editable = entry.session.isEditable(entry.record)
        let mine = entry.record.transaction.authorID == entry.session.authorID
        Group {
            if editable {
                Button { edit(entry) } label: { LedgerRow(record: entry.record, session: entry.session, showsDate: false) }
                    .buttonStyle(.plain)
            } else if mine {
                LedgerRow(record: entry.record, session: entry.session, showsDate: false)
            } else {
                // Someone else's record: who and when, nothing to change.
                VStack(alignment: .leading, spacing: 0) {
                    LedgerRow(record: entry.record, session: entry.session, showsDate: false)
                    Text("\(entry.session.payerName(for: entry.record)) · \(entry.record.transaction.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.bottom, FolkiSpacing.xs)
                }
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
