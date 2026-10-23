import SwiftUI
import UIKit
import FolkiDuoCore

struct FolkiRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var selectedDay: Date?
    /// Whether this iPhone had no personal budget when Folki opened. Decided once from the data, not a flag:
    /// a reinstall or a second device with the budget already in iCloud skips the welcome.
    @State private var startedWithoutBudget: Bool
    /// The step reached so far; survives a relaunch (for example after changing the app language).
    @AppStorage("FolkiOnboardingStep") private var onboardingStep = OnboardingView.Step.hello.rawValue
    @AppStorage("FolkiFirstSpendTip") private var firstSpendTip = false
    @State private var finishedOnboarding = false
    enum TabID: Hashable { case budget, plan }
    @State private var tab: TabID = .budget
    @State private var budgetInHistory = false
    @State private var budgetReturnRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set by a widget or intent link; the budget screen opens the matching sheet.
    @State private var pendingEntry: URL?
    @State private var pendingEnvelope: UUID?
    @Environment(\.scenePhase) private var scenePhase

    init(personal: BudgetSession, family: BudgetSession) {
        self.personal = personal; self.family = family
        _startedWithoutBudget = State(initialValue: personal.household == nil)
    }

    /// Everything the plan reminders and widgets depend on: envelopes, what is put aside, today's figures.
    private var reminderSignature: [String] {
        [personal, family].flatMap { session in
            session.envelopes.map { "\($0.id)\($0.nextDue.timeIntervalSince1970)\($0.size.minorUnits)\(session.envelopeBalance($0).minorUnits)" }
                + ["\(session.result?.todayRemaining.minorUnits ?? 0)/\(session.result?.todayGuide.minorUnits ?? 0)"]
        }
    }

    /// Decided before anything is drawn, so the main screen never flashes behind the onboarding.
    private var needsOnboarding: Bool {
        guard !finishedOnboarding else { return false }
        // `-FolkiShowOnboarding YES` forces it for checks.
        if UserDefaults.standard.bool(forKey: "FolkiShowOnboarding") { return true }
        return startedWithoutBudget && !personal.isDemo
    }

    private func selectTab(_ value: TabID) {
        guard tab != value else { return }
        FolkiFeedback.selection()
        tab = value
    }

    var body: some View {
        if needsOnboarding {
            OnboardingView(personal: personal, family: family) {
                // Mount the main screen once at its final size; its rings animate independently.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    firstSpendTip = true
                    onboardingStep = OnboardingView.Step.hello.rawValue
                    finishedOnboarding = true
                }
            }
            .transition(.opacity)
        } else {
            TabView(selection: Binding(get: { tab }, set: { value in
                // Tapping Budget while the list is open (the bar is collapsed to one icon) returns to the rings.
                if value == .budget && tab == .budget { budgetReturnRequest += 1 } else { selectTab(value) }
            })) {
                Tab("Бюджет", systemImage: "wallet.bifold", value: TabID.budget) {
                    BudgetRootView(personal: personal, family: family, selectedDay: $selectedDay,
                                   pendingEntry: $pendingEntry, inHistory: $budgetInHistory,
                                   returnRequest: budgetReturnRequest) { selectTab(.plan) }
                }
                Tab("План", systemImage: "list.bullet.clipboard", value: TabID.plan) {
                    PlanTab(personal: personal, family: family, pendingEnvelope: $pendingEnvelope)
                }
            }
            // Both tabs stay in sight: a minimized bar hid «План» after any scroll.
            .tabBarMinimizeBehavior(.never)
            .tint(Color.folkiAccent)
            .transition(.identity)
            .onChange(of: reminderSignature) { reschedule() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { reschedule() } }
            .task { reschedule() }
            .onOpenURL { url in
                guard url.scheme == "folki" else { return }
                if url.host == "envelope" {
                    selectTab(.plan)
                    pendingEnvelope = UUID(uuidString: url.lastPathComponent)
                } else {
                    selectTab(.budget)
                    pendingEntry = url
                }
            }
        }
    }

}

extension FolkiRootView {
    private func reschedule() {
        let sessions = [personal, family]
        WidgetBridge.publish(personal: personal, family: family)
        Task { await PlanReminders.reschedule(PlanSettings.load(), sessions: sessions) }
    }
}

/// iCloud-style initials for members without an uploaded profile photo.
struct MemberAvatar: View {
    let name: String
    private var initials: String {
        let letters = name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
    var body: some View {
        Text(initials).font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(LinearGradient(colors: [Color.gray.opacity(0.65), Color.gray], startPoint: .top, endPoint: .bottom), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A fixed date row below the system navigation title on every main screen.
struct FolkiDateHeader: View {
    let date: Date
    var body: some View {
        Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
