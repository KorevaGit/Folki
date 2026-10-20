import SwiftUI
import FolkiDuoCore

struct BudgetHistoryView: View {
    let session: BudgetSession
    @State private var showDeleted = false
    @State private var editing: LedgerRecord?
    @State private var adding = false
    @State private var errorMessage: String?
    private var records: [LedgerRecord] {
        session.historyRecords.filter { $0.transaction.isDeleted == showDeleted }.reversed()
    }

    private var days: [(Date, [LedgerRecord])] {
        let calendar = session.calendar
        var order: [Date] = [], groups: [Date: [LedgerRecord]] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.transaction.date)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(record)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
    private func dayTitle(_ day: Date) -> String {
        let calendar = session.calendar
        if calendar.isDate(day, inSameDayAs: session.referenceDate) { return String(localized: "Сегодня") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: session.referenceDate),
           calendar.isDate(day, inSameDayAs: yesterday) { return String(localized: "Вчера") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    var body: some View {
        List {
            // Grouped by day, newest first, like Wallet.
            ForEach(days, id: \.0) { day, items in
              Section {
                ForEach(items) { record in
                VStack(alignment: .leading) {
                    if record.transaction.isDeleted {
                        LedgerRow(record: record, session: session, showsDate: false)
                        Button("Восстановить запись", systemImage: "arrow.uturn.backward") {
                            setDeleted(false, record: record)
                        }.buttonStyle(.bordered)
                    } else if session.isEditable(record) {
                        Button { editing = record } label: {
                            LedgerRow(record: record, session: session, showsDate: false)
                        }.buttonStyle(.plain)
                    } else {
                        LedgerRow(record: record, session: session, showsDate: false)
                    }
                }
                .swipeActions {
                    if session.canCancelContribution(record) {
                        Button("Отменить взнос", role: .destructive) { cancelContribution(record) }
                    } else if !session.isEditable(record) {
                        EmptyView()
                    } else if record.transaction.isDeleted {
                        Button("Восстановить") { setDeleted(false, record: record) }
                    } else {
                        Button("Удалить", role: .destructive) { setDeleted(true, record: record) }
                    }
                }
                }
              } header: {
                Text(dayTitle(day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
              }
            }
        }
        .folkiFormLayout()
        .id(showDeleted)
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(showDeleted ? String(localized: "Удалённых записей нет") : String(localized: "Записей пока нет"),
                    systemImage: "list.bullet.rectangle",
                    description: Text(showDeleted ? String(localized: "Здесь можно восстановить удалённые записи.") : String(localized: "Добавь первую запись в бюджете.")))
            }
        }
        .navigationTitle(showDeleted ? String(localized: "Удалённые") : String(localized: "История"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Показать записи", systemImage: "line.3.horizontal.decrease") {
                    Button("Активные", systemImage: "list.bullet") { showDeleted = false }
                    Button("Удалённые", systemImage: "trash") { showDeleted = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Добавить запись", systemImage: "plus") { adding = true }
                    .disabled(session.result == nil)
            }
        }
        .sheet(item: $editing) { ExpenseEditorView(session: session, editing: $0) }
        .sheet(isPresented: $adding) { ExpenseEditorView(session: session) }
        .alert("Запись не изменена", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Готово") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func cancelContribution(_ record: LedgerRecord) {
        do { try session.cancelContribution(record); FolkiFeedback.boundary() }
        catch { errorMessage = String(localized: "Не получилось отменить взнос. Обнови историю и повтори.") }
    }

    private func setDeleted(_ deleted: Bool, record: LedgerRecord) {
        do { try session.setDeleted(deleted, record: record); FolkiFeedback.boundary() }
        catch { errorMessage = String(localized: "Не получилось изменить запись. Обнови историю и повтори.") }
    }
}
