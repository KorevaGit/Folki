import SwiftUI
import FolkiDuoCore
import FolkiDuoPersistence

struct SharingView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    @State private var name = ""
    @State private var inviteLink: URL?
    @State private var preparingLink = false
    @State private var inviteError: String?
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
                            if let inviteLink {
                                ShareLink(item: inviteLink, preview: SharePreview("Семейный бюджет Folki", image: Image("LaunchHouse"))) {
                                    Label("Отправить приглашение", systemImage: "person.badge.plus")
                                }
                            } else {
                                Button { Task { await prepareLink(repository, householdID) } } label: {
                                    Label(preparingLink ? "Готовлю ссылку…" : "Создать ссылку-приглашение", systemImage: "link")
                                }.disabled(preparingLink)
                            }
                            // Right under the button: at the bottom of the list it went unnoticed.
                            if let inviteError { FolkiErrorMessage(message: inviteError) }
                        } footer: {
                            Text("Ссылку можно отправить в любой мессенджер. Кто откроет её на iPhone, попадёт в семью — всего до пяти человек.")
                        }
                        .disabled(session.members.filter(\.isActive).count >= 5)
                        // A family invited before already has a link; it is checked with iCloud before it is offered.
                        .task { if (try? repository.existingShare(householdID: householdID)) != nil { await prepareLink(repository, householdID) } }
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

extension SharingView {
    /// The share is saved to iCloud here, so a failure shows under the button instead of in the share sheet.
    private func prepareLink(_ repository: BudgetRepository, _ householdID: UUID) async {
        preparingLink = true; defer { preparingLink = false }
        do { inviteLink = try await repository.share(householdID: householdID).url; inviteError = nil }
        catch { inviteError = SharingView.inviteFailure(error) }
    }
    /// The error code stays in the text: it is the only clue from a TestFlight build.
    nonisolated static func inviteFailure(_ error: Error) -> String {
        if (error as? LedgerError) == .cloudNotConfigured {
            return String(localized: "iCloud ещё не ответил. Нажми «Проверить iCloud» и отправь приглашение снова.")
        }
        if (error as? LedgerError) == .unavailable {
            return String(localized: "iCloud сохранил приглашение без ссылки. Попробуй ещё раз через минуту.")
        }
        let code = (error as NSError).code
        return String(localized: "Ссылка не создана: iCloud вернул ошибку \(code). Проверь сеть и вход в iCloud.")
    }
}
