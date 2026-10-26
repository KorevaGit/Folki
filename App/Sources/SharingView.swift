import SwiftUI
import CloudKit
import FolkiDuoCore

struct SharingView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    @State private var name = ""
    @State private var existingShare: CKShare?
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
                        } label: { HStack(spacing: 12) { MemberAvatar(name: member.name); Text(session.memberName(member.id)); Spacer(); Image(systemName: "pencil").foregroundStyle(Color.folkiSecondary) } }
                        if member.id != session.authorID {
                            Button("Убрать \(session.memberName(member.id)) из семьи", role: .destructive) {
                                removingMember = member
                            }.font(FolkiFont.footnote)
                        }
                    }
                    Text("Можно позвать до четырёх близких. Личный бюджет у каждого свой.").folkiText(.footnote)
                }
                if session.household == nil {
                    Section {
                        Button("Создать семью") {
                            do { try session.ensureDailyPeriod() }
                            catch { errorMessage = String(localized: "Не получилось создать семью. Попробуй ещё раз.") }
                        }
                    }
                } else if let repository = session.repository, let identifier = repository.cloudIdentifier {
                    if (try? repository.ownsFamily()) == true, let householdID = session.household?.id {
                        Section {
                            ShareLink(item: FamilyInvitation(share: existingShare, container: CKContainer(identifier: identifier)) {
                                try await repository.share(householdID: householdID)
                            }, preview: SharePreview("Семейный бюджет Folki", image: Image("LaunchHouse"))) {
                                Label("Отправить приглашение", systemImage: "person.badge.plus")
                            }.disabled(session.members.filter(\.isActive).count >= 5)
                        } footer: {
                            Text("Ссылку можно отправить в любой мессенджер. Кто откроет её на iPhone, попадёт в семью — всего до пяти человек.")
                        }
                        .task { existingShare = try? repository.existingShare(householdID: householdID) }
                    }
                } else {
                    Section("Добавить участника") {
                        TextField("Имя", text: $name)
                        Button("Добавить для учёта") {
                            do { try session.addMember(name: name); name = "" }
                            catch { errorMessage = String(localized: "В семье уже пять человек — это максимум") }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.members.filter(\.isActive).count >= 5 || session.result == nil)
                        Text("Этот участник пока только на этом телефоне.").folkiText(.footnote)
                    }
                }
                if let repository = session.repository, repository.cloudIdentifier != nil,
                   session.household == nil || (try? repository.ownsFamily()) == true {
                    Section {
                        PasteButton(payloadType: URL.self) { urls in
                            guard let url = urls.first else { return }
                            Task { @MainActor in dismiss(); await FolkiApplication.shared.join(url) }
                        }
                    } header: { Text("Меня пригласили") } footer: {
                        Text("Открой ссылку из сообщения на этом iPhone или скопируй её и вставь сюда. Личный бюджет не изменится.")
                    }
                }
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }
            .folkiFormLayout()
            .navigationTitle("Семья и доступ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .confirmationDialog("Убрать участника? Его записи сохранятся, облачный доступ будет отозван.", isPresented: Binding(get: { removingMember != nil }, set: { if !$0 { removingMember = nil } }), titleVisibility: .visible) {
                if let member = removingMember {
                    Button("Убрать \(session.memberName(member.id))", role: .destructive) {
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

/// The family invitation for the share sheet: a link anyone can open, with edit rights.
private struct FamilyInvitation: Transferable {
    let share: CKShare?
    let container: CKContainer
    let prepare: @Sendable () async throws -> CKShare

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { invitation in
            let options = CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite,
                                                  allowedParticipantAccessOptions: .anyoneWithLink)
            if let share = invitation.share {
                return .existing(share, container: invitation.container, allowedSharingOptions: options)
            }
            return .prepareShare(container: invitation.container, allowedSharingOptions: options, preparationHandler: invitation.prepare)
        }
    }
}
