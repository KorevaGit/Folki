import SwiftUI
import CloudKit
import FolkiDuoPersistence

@MainActor @Observable
final class FolkiApplication {
    static let shared = FolkiApplication()
    var session: BudgetSession?
    var personalSession: BudgetSession?
    var openingError: String?
    var invitationError: String?
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
                in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Folki")
            let identifier = (Bundle.main.object(forInfoDictionaryKey: "FolkiCloudContainer") as? String)
                .flatMap { $0.hasPrefix("iCloud.") ? $0 : nil }
            let repository = try await BudgetRepository.open(directory: directory, cloudIdentifier: identifier, localMemberID: memberID)
            await repository.verifyAccount()
            personalSession = BudgetSession(scope: .personal, repository: repository)
            session = BudgetSession(scope: .family, repository: repository)
            await acceptPendingInvitations()
        } catch { openingError = "Не удалось открыть хранилище Folki. Данные не удалены. Попробуйте ещё раз." }
        #endif
    }
    func receive(_ metadata: CKShare.Metadata) {
        pendingInvitations.append(metadata)
        Task { await acceptPendingInvitations() }
    }
    func acceptPendingInvitations() async {
        guard !acceptingInvitation, let repository = session?.repository else { return }
        acceptingInvitation = true
        defer { acceptingInvitation = false }
        while let metadata = pendingInvitations.first {
            do {
                try await repository.accept(metadata)
                pendingInvitations.removeFirst()
                invitationError = nil
                session?.refresh()
            } catch {
                invitationError = "Приглашение не принято. Для вступления нужно пустое пространство и доступный iCloud. Локальный бюджет не заменён."
                return
            }
        }
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
                } else { ProgressView("Открываем Folki…") }
            }
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .task { await model.open() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.session?.refresh(); model.personalSession?.refresh() }
            }
            .alert("Общий бюджет", isPresented: Binding(get: { model.invitationError != nil }, set: { if !$0 { model.invitationError = nil } })) {
                Button("Повторить") { Task { await model.acceptPendingInvitations() } }
                Button("Закрыть", role: .cancel) { model.invitationError = nil }
            } message: { Text(model.invitationError ?? "") }
        }
    }
}
