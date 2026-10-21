import SwiftUI
import FolkiDuoCore

/// "Траты за период": both budgets in one list, days as sticky headers with the day's total.
/// Own records open for editing and delete with an undo; other people's are read-only.
struct PeriodHistorySheet: View {
    let personal: BudgetSession
    let family: BudgetSession
    @Environment(\.dismiss) private var dismiss

    enum Filter: Hashable { case all, personal, family }
    @State private var filter: Filter = .all
    @State private var editing: Entry?
    @State private var undo: Entry?
    @State private var errorMessage: String?

    struct Entry: Identifiable {
        let record: LedgerRecord
        let session: BudgetSession
        var id: String { session.scope.rawValue + record.id.uuidString }
    }

    private var hasFamily: Bool { family.household != nil }
    private var sessions: [BudgetSession] {
        switch filter {
        case .all: hasFamily ? [personal, family] : [personal]
        case .personal: [personal]
        case .family: [family]
        }
    }
    private var entries: [Entry] {
        sessions.flatMap { session in session.records.map { Entry(record: $0, session: session) } }
            .sorted { $0.record.transaction.date > $1.record.transaction.date }
    }
    private var days: [(Date, [Entry])] {
        let calendar = personal.calendar
        var order: [Date] = [], groups: [Date: [Entry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.record.transaction.date)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if hasFamily {
                    FolkiSegmentedPicker(title: String(localized: "Показать"), selection: $filter,
                        options: [(String(localized: "Все"), .all), (String(localized: "Личные"), .personal), (String(localized: "Семейные"), .family)],
                        minimumHeight: 36)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                ForEach(days, id: \.0) { day, items in
                    Section {
                        ForEach(items) { entry in row(entry) }
                    } header: { header(day, items) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("Трат пока нет", systemImage: "basket",
                        description: Text("Записанные траты появятся здесь"))
                }
            }
            .overlay(alignment: .bottom) { undoToast }
            .navigationTitle("Траты за период").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .sheet(item: $editing) { ExpenseEditorView(session: $0.session, editing: $0.record) }
            .alert("Запись не изменена", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Готово") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .presentationDetents([.large])
    }

    private func header(_ day: Date, _ items: [Entry]) -> some View {
        let spent = items.filter { $0.record.transaction.kind == .expense }.reduce(Int64(0)) { $0 + $1.record.transaction.amount.minorUnits }
        return HStack {
            Text(dayTitle(day)).font(.subheadline.weight(.semibold))
            Spacer()
            if spent > 0 {
                Text("−\(MoneyText.whole(Money(minorUnits: spent)))").font(.subheadline).monospacedDigit()
            }
        }
        .foregroundStyle(.secondary).textCase(nil)
    }

    @ViewBuilder private func row(_ entry: Entry) -> some View {
        let editable = entry.session.isEditable(entry.record)
        Group {
            if editable {
                Button { editing = entry } label: { LedgerRow(record: entry.record, session: entry.session, showsDate: false) }
                    .buttonStyle(.plain)
            } else if entry.record.transaction.authorID == entry.session.authorID {
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
        .swipeActions {
            if entry.session.canCancelContribution(entry.record) {
                Button("Отменить взнос", role: .destructive) { cancel(entry) }
            } else if editable {
                Button("Удалить", role: .destructive) { delete(entry) }
            }
        }
    }

    @ViewBuilder private var undoToast: some View {
        if let undo {
            HStack(spacing: FolkiSpacing.item) {
                Text("Запись удалена").font(.subheadline)
                Spacer(minLength: 0)
                Button("Вернуть") { restore(undo) }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, FolkiSpacing.page).frame(minHeight: 52)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.xs)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undo.id) {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(FolkiMotion.standard) { self.undo = nil }
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

    private func delete(_ entry: Entry) {
        do {
            try entry.session.setDeleted(true, record: entry.record)
            FolkiFeedback.saved()
            withAnimation(FolkiMotion.standard) { undo = entry }
        } catch { errorMessage = String(localized: "Не получилось изменить запись. Обнови историю и повтори.") }
    }
    private func restore(_ entry: Entry) {
        // The deleted record has a new revision; restore the stored one.
        let current = entry.session.deletedRecords.first { $0.id == entry.record.id } ?? entry.record
        do {
            try entry.session.setDeleted(false, record: current)
            FolkiFeedback.saved()
            withAnimation(FolkiMotion.standard) { undo = nil }
        } catch { errorMessage = String(localized: "Не получилось вернуть запись. Попробуй ещё раз.") }
    }
    private func cancel(_ entry: Entry) {
        do { try entry.session.cancelContribution(entry.record); FolkiFeedback.saved() }
        catch { errorMessage = String(localized: "Не получилось отменить взнос. Обнови историю и повтори.") }
    }
}
