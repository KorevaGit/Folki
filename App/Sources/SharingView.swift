import SwiftUI
import CloudKit
import CoreData
import FolkiDuoPersistence

struct SharingView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    @State private var share: CKShare?
    @State private var preparing = false
    @State private var showingController = false
    @State private var errorMessage: String?
    @State private var creatingBudget = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Хранение") {
                    Text(session.repository?.statusText ?? "Демонстрационный режим")
                    if let repository = session.repository, repository.cloudIdentifier != nil {
                        Button("Проверить iCloud") {
                            Task { await repository.verifyAccount(); session.refresh() }
                        }
                    }
                    if let last = session.repository?.lastCloudUpdate {
                        LabeledContent("Последний обмен") { Text(last, format: .dateTime.day().month().hour().minute()) }
                    }
                    Text("Экспорт в iCloud не подтверждает, что партнёр уже открыл запись.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Общий бюджет") {
                    if session.household == nil {
                        Text("Сначала создайте семейный план. Личный бюджет сохранится отдельно.")
                        Button("Создать семейный бюджет") { creatingBudget = true }
                    }
                    if let repository = session.repository, repository.cloudIdentifier != nil {
                        Text("Пригласите одного партнёра с правом изменения. Доступ по приглашению; публичная ссылка выключена.")
                        Button(preparing ? "Подготовка…" : "Пригласить или настроить доступ") {
                            guard let household = session.household else { return }
                            preparing = true
                            Task {
                                defer { preparing = false }
                                do {
                                    share = try await repository.share(householdID: household.id)
                                    showingController = true
                                } catch {
                                    errorMessage = "Не удалось подготовить приглашение. Проверьте iCloud и повторите после обмена."
                                }
                            }
                        }.disabled(preparing || session.household == nil)
                    } else {
                        Text("Сейчас включено локальное хранение. Для обмена нужна сборка с iCloud и подписью вашей команды Apple Developer.")
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .sheet(isPresented: $showingController) {
                if let share, let repository = session.repository, let identifier = repository.cloudIdentifier {
                    CloudSharingController(share: share, identifier: identifier, repository: repository)
                }
            }
            .navigationTitle("Семья и доступ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .sheet(isPresented: $creatingBudget) { BudgetSetupView(session: session) }
        }
    }
}

private struct CloudSharingController: UIViewControllerRepresentable {
    let share: CKShare
    let identifier: String
    let repository: BudgetRepository
    func makeCoordinator() -> Coordinator { Coordinator(repository: repository) }
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: CKContainer(identifier: identifier))
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let repository: BudgetRepository
        init(repository: BudgetRepository) { self.repository = repository }
        func itemTitle(for csc: UICloudSharingController) -> String? { "Общий бюджет Folki" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            repository.reportSharingError()
        }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            guard let share = csc.share else { return }
            Task {
                do {
                    let store = share.currentUserParticipant?.role == .owner ? repository.privateStore : repository.sharedStore
                    guard let store else { return }
                    try await repository.persist(share: share, store: store)
                } catch { repository.reportSharingError() }
            }
        }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            // Core Data handles the shared-zone removal; remote notifications reload snapshots.
            repository.sharingStopped()
        }
    }
}
