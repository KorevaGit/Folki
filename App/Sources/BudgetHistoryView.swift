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

    var body: some View {
        List {
            ForEach(records) { record in
                VStack(alignment: .leading) {
                    if record.transaction.isDeleted {
                        LedgerRow(record: record, session: session)
                        Button("Восстановить запись", systemImage: "arrow.uturn.backward") {
                            setDeleted(false, record: record)
                        }.buttonStyle(.bordered)
                    } else if session.isEditable(record) {
                        Button { editing = record } label: {
                            LedgerRow(record: record, session: session)
                        }.buttonStyle(.plain)
                    } else {
                        LedgerRow(record: record, session: session)
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
        }
        .folkiFormLayout()
        .id(showDeleted)
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(showDeleted ? "Удалённых записей нет" : "Записей пока нет",
                    systemImage: "list.bullet.rectangle",
                    description: Text(showDeleted ? "Здесь можно восстановить удалённые записи." : "Добавь первую запись в бюджете."))
            }
        }
        .navigationTitle(showDeleted ? "Удалённые" : session.scope.title + " · история")
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
        do { try session.cancelContribution(record) }
        catch { errorMessage = "Не удалось отменить взнос. Обнови историю и повтори." }
    }

    private func setDeleted(_ deleted: Bool, record: LedgerRecord) {
        do { try session.setDeleted(deleted, record: record) }
        catch { errorMessage = "Не удалось изменить запись. Обнови историю и повтори." }
    }
}
