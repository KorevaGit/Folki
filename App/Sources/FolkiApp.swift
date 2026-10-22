import SwiftUI
import CloudKit
import FolkiDuoCore
import FolkiDuoPersistence

@MainActor @Observable
final class FolkiApplication {
    static let shared = FolkiApplication()
    var session: BudgetSession?
    var personalSession: BudgetSession?
    var openingError: String?
    var invitationError: String?
    /// An invitation that would replace a family budget with records; waits for the user's answer.
    var replacementPending = false
    private var pendingInvitations: [CKShare.Metadata] = []
    private var acceptingInvitation = false

    func open() async {
        guard session == nil else { return }
        openingError = nil
        #if FOLKI_DEMO
        personalSession = DemoFixtures.makePersonalSession()
        session = DemoFixtures.makeSession()
        #else
        do {
            let defaults = UserDefaults.standard
            let key = "FolkiBudgetMemberID"
            let memberID = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
            defaults.set(memberID.uuidString, forKey: key)
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                // v1 is the clean schema of the release; stores of pre-release schemas are left unread.
                .appendingPathComponent("Folki").appendingPathComponent("v1")
            let identifier = (Bundle.main.object(forInfoDictionaryKey: "FolkiCloudContainer") as? String)
                .flatMap { $0.hasPrefix("iCloud.") ? $0 : nil }
            let repository = try await BudgetRepository.open(directory: directory, cloudIdentifier: identifier, localMemberID: memberID)
            await repository.verifyAccount()
            #if DEBUG
            // `-FolkiInitializeCloudSchema YES` pushes the whole schema to the development container.
            if UserDefaults.standard.bool(forKey: "FolkiInitializeCloudSchema") { try? repository.initializeCloudSchema() }
            #endif
            personalSession = BudgetSession(scope: .personal, repository: repository)
            session = BudgetSession(scope: .family, repository: repository)
            await acceptPendingInvitations()
        } catch { openingError = String(localized: "Не получилось открыть хранилище Folki. Данные не удалены. Попробуй ещё раз.") }
        #endif
    }
    func receive(_ metadata: CKShare.Metadata) {
        pendingInvitations.append(metadata)
        Task { await acceptPendingInvitations() }
    }
    func acceptPendingInvitations(replacingExisting: Bool = false) async {
        guard !acceptingInvitation, let repository = session?.repository else { return }
        acceptingInvitation = true
        defer { acceptingInvitation = false }
        while let metadata = pendingInvitations.first {
            do {
                try await repository.accept(metadata, replacingExisting: replacingExisting)
                pendingInvitations.removeFirst()
                invitationError = nil
                session?.refresh()
            } catch LedgerError.familyHasRecords {
                replacementPending = true
                return
            } catch {
                invitationError = String(localized: "Не получилось принять приглашение. Проверь, что iCloud включён, и открой ссылку ещё раз. Личный бюджет не изменился.")
                return
            }
        }
    }
    func declinePendingInvitation() {
        if !pendingInvitations.isEmpty { pendingInvitations.removeFirst() }
        replacementPending = false
    }
}

final class FolkiAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let identifier = Bundle.main.object(forInfoDictionaryKey: "FolkiCloudContainer") as? String,
           identifier.hasPrefix("iCloud.") {
            application.registerForRemoteNotifications()
        }
        return true
    }
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        FolkiApplication.shared.receive(metadata)
    }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = FolkiSceneDelegate.self
        return configuration
    }
}
final class FolkiSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { FolkiApplication.shared.receive(metadata) }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        FolkiApplication.shared.receive(metadata)
    }
}

@main
struct FolkiApp: App {
    @UIApplicationDelegateAdaptor(FolkiAppDelegate.self) private var delegate
    @State private var model = FolkiApplication.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            Group {
                if let session = model.session, let personal = model.personalSession {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        FolkiRootView(personal: personal, family: session)
                            .onChange(of: context.date) { session.refresh(); personal.refresh() }
                            .onChange(of: session.repository?.changeToken) { session.refresh(); personal.refresh() }
                    }
                } else if let error = model.openingError {
                    ContentUnavailableView {
                        Label("Хранилище недоступно", systemImage: "externaldrive.badge.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button("Повторить") { Task { await model.open() } }
                    }
                } else { LaunchHouseView() }
            }
            .task { await model.open() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.session?.refresh(); model.personalSession?.refresh() }
            }
            .alert("Общий бюджет", isPresented: Binding(get: { model.invitationError != nil }, set: { if !$0 { model.invitationError = nil } })) {
                Button("Повторить") { Task { await model.acceptPendingInvitations() } }
                Button("Закрыть", role: .cancel) { model.invitationError = nil }
            } message: { Text(model.invitationError ?? "") }
            .alert("Вступить в другую семью?", isPresented: Binding(get: { model.replacementPending }, set: { if !$0 { model.replacementPending = false } })) {
                Button("Вступить", role: .destructive) {
                    model.replacementPending = false
                    Task { await model.acceptPendingInvitations(replacingExisting: true) }
                }
                Button("Отмена", role: .cancel) { model.declinePendingInvitation() }
            } message: {
                Text("Записи и конверты твоего семейного бюджета удалятся. Личный бюджет не изменится.")
            }
        }
    }
}

/// While the store opens: the launch screen's house stays in place; words appear only if it takes a while.
private struct LaunchHouseView: View {
    @State private var slow = false
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Image("LaunchHouse").accessibilityHidden(true)
            Text("Открываем Folki…").font(.subheadline).foregroundStyle(.secondary)
                .offset(y: 72).opacity(slow ? 1 : 0)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(FolkiMotion.quick) { slow = true }
        }
    }
}
