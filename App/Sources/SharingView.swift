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
    @State private var editingMember: Member?
    @State private var editedName = ""
    @State private var removingMember: Member?
    var body: some View {
        NavigationStack {
            Form {
                Section("Хранение") {
                    Text(session.repository?.statusText ?? String(localized: "Демонстрационный режим"))
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
                    Text("Ты можешь позвать до 4 близких 🏡 Личные бюджеты у каждого свои.").font(.footnote).foregroundStyle(.secondary)
                }
                if session.household == nil {
                    Section {
                        Button("Создать семью") {
                            do { try session.ensureDailyPeriod() }
                            catch { errorMessage = String(localized: "Не получилось создать семью. Попробуй ещё раз.") }
                        }
                    }
                } else {
                    Section(session.repository?.cloudIdentifier == nil ? String(localized: "Добавить участника") : String(localized: "Пригласить по Apple ID")) {
                        TextField("Имя", text: $name)
                        if session.repository?.cloudIdentifier != nil {
                            TextField("Email Apple ID", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                            Button(preparing ? String(localized: "Готовим…") : String(localized: "Создать приглашение")) {
                                guard let repository = session.repository, let budget = session.storedBudget else { return }
                                preparing = true; invitationURL = nil
                                Task {
                                    defer { preparing = false }
                                    do { invitationURL = try await repository.inviteFamilyMember(email: email, name: name, in: budget, asOf: session.referenceDate); session.refresh() }
                                    catch { errorMessage = String(localized: "Не получилось 😕 Проверь Apple ID и попробуй ещё раз.") }
                                }
                            }.disabled(preparing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || email.isEmpty)
                            if let invitationURL { ShareLink("Отправить приглашение", item: invitationURL) }
                            Text("Отправь ссылку — человек откроет её и сразу окажется в вашем бюджете 💌").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button("Добавить для учёта") {
                                do { try session.addMember(name: name); name = "" }
                                catch { errorMessage = String(localized: "В семье уже 5 человек — это максимум 🙂") }
                            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.members.filter(\.isActive).count >= 5 || session.result == nil)
                            Text("Этот участник пока только на этом телефоне.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }
            .folkiFormLayout()
            .navigationTitle("Семья и доступ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .confirmationDialog("Убрать участника? Его записи сохранятся, облачный доступ будет отозван.", isPresented: Binding(get: { removingMember != nil }, set: { if !$0 { removingMember = nil } }), titleVisibility: .visible) {
                if let member = removingMember {
                    Button("Убрать \(member.name)", role: .destructive) {
                        guard let repository = session.repository, let budget = session.storedBudget else { return }
                        Task {
                            do { try await repository.removeFamilyMember(member, in: budget, asOf: session.referenceDate); session.refresh() }
                            catch { errorMessage = String(localized: "Не получилось убрать участника. Для отзыва облачного доступа нужны права владельца и сеть.") }
                        }
                    }
                }
            }
            .alert("Имя участника", isPresented: Binding(get: { editingMember != nil }, set: { if !$0 { editingMember = nil } })) {
                TextField("Имя", text: $editedName)
                Button("Сохранить") {
                    guard let member = editingMember else { return }
                    do { try session.renameMember(member, name: editedName) }
                    catch { errorMessage = String(localized: "Имя не сохранено.") }
                    editingMember = nil
                }
                Button("Отмена", role: .cancel) { editingMember = nil }
            }
        }
    }
}
