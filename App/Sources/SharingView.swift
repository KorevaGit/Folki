import SwiftUI
import FolkiDuoCore

struct SharingView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    @State private var name = ""
    @State private var email = ""
    @State private var preparing = false
    @State private var invitationURL: URL?
    @State private var errorMessage: String?
    @State private var creatingBudget = false
    @State private var editingMember: Member?
    @State private var editedName = ""
    @State private var removingMember: Member?
    var body: some View {
        NavigationStack {
            Form {
                Section("Хранение") {
                    Text(session.repository?.statusText ?? "Демонстрационный режим")
                    if let repository = session.repository, repository.cloudIdentifier != nil {
                        Button("Проверить iCloud") { Task { await repository.verifyAccount(); session.refresh() } }
                    }
                }
                Section("Семья · \(session.members.filter(\.isActive).count) из 5") {
                    ForEach(session.members.filter(\.isActive)) { member in
                        Button {
                            editingMember = member; editedName = session.memberName(member.id)
                        } label: { HStack(spacing: 12) { MemberAvatar(name: member.name); Text(session.memberName(member.id)); Spacer(); Image(systemName: "pencil").foregroundStyle(.secondary) } }
                        if member.id != session.authorID {
                            Button("Убрать \(member.name) из семьи", role: .destructive) {
                                removingMember = member
                            }.font(.caption)
                        }
                    }
                    Text("До пяти участников вместе с владельцем. Личные бюджеты не входят в общий доступ. Имена можно изменить. При удалении участника его прежние операции и имя сохраняются в истории.").font(.footnote).foregroundStyle(.secondary)
                }
                if session.household == nil {
                    Section {
                        Text("Сначала создай семейный план. Личные данные сохранятся отдельно.")
                        Button("Создать семейный бюджет") { creatingBudget = true }
                    }
                } else {
                    Section(session.repository?.cloudIdentifier == nil ? "Добавить участника" : "Пригласить по Apple ID") {
                        TextField("Имя", text: $name)
                        if session.repository?.cloudIdentifier != nil {
                            TextField("Email Apple ID", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                            Button(preparing ? "Подготовка…" : "Подготовить приглашение") {
                                guard let repository = session.repository, let budget = session.storedBudget else { return }
                                preparing = true; invitationURL = nil
                                Task {
                                    defer { preparing = false }
                                    do { invitationURL = try await repository.inviteFamilyMember(email: email, name: name, in: budget, asOf: session.referenceDate); session.refresh() }
                                    catch { errorMessage = "Приглашение не подготовлено. Проверь Apple ID, права владельца и свободное место. После ошибки обмена повтори для того же Apple ID." }
                                }
                            }.disabled(preparing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || email.isEmpty)
                            if let invitationURL { ShareLink("Отправить приглашение", item: invitationURL) }
                            Text("Приглашает владелец. Учитываются также ожидающие приглашения; публичный доступ отключён. После подготовки отправьте ссылку указанному человеку. Принимающему не нужно создавать отдельный семейный бюджет.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button("Добавить для учёта") {
                                do { try session.addMember(name: name); name = "" }
                                catch { errorMessage = "Не удалось добавить участника. В семье может быть не больше пяти человек." }
                            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.members.filter(\.isActive).count >= 5 || session.result == nil)
                            Text("Это участник локального учёта, без доступа с другого устройства. Обмен доступен в сборке iCloud.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }
            .folkiFormLayout()
            .navigationTitle("Семья и доступ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .sheet(isPresented: $creatingBudget) { BudgetSetupView(session: session) }
            .confirmationDialog("Убрать участника? Его записи сохранятся, облачный доступ будет отозван.", isPresented: Binding(get: { removingMember != nil }, set: { if !$0 { removingMember = nil } }), titleVisibility: .visible) {
                if let member = removingMember {
                    Button("Убрать \(member.name)", role: .destructive) {
                        guard let repository = session.repository, let budget = session.storedBudget else { return }
                        Task {
                            do { try await repository.removeFamilyMember(member, in: budget, asOf: session.referenceDate); session.refresh() }
                            catch { errorMessage = "Не удалось убрать участника. Для отзыва облачного доступа нужны права владельца и сеть." }
                        }
                    }
                }
            }
            .alert("Имя участника", isPresented: Binding(get: { editingMember != nil }, set: { if !$0 { editingMember = nil } })) {
                TextField("Имя", text: $editedName)
                Button("Сохранить") {
                    guard let member = editingMember else { return }
                    do { try session.renameMember(member, name: editedName) }
                    catch { errorMessage = "Имя не сохранено." }
                    editingMember = nil
                }
                Button("Отмена", role: .cancel) { editingMember = nil }
            }
        }
    }
}
