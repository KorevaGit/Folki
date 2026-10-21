import SwiftUI
import UIKit
import FolkiDuoCore

struct FolkiRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var selectedDay: Date?
    @AppStorage("FolkiOnboarded") private var onboarded = false
    /// The step reached so far; survives a relaunch (for example after changing the app language).
    @AppStorage("FolkiOnboardingStep") private var onboardingStep = 0
    @AppStorage("FolkiFirstSpendTip") private var firstSpendTip = false
    @State private var finishedOnboarding = false
    enum TabID: Hashable { case budget, plan }
    @State private var tab: TabID = .budget
    @Environment(\.scenePhase) private var scenePhase

    /// Everything the plan reminders depend on: dates, sizes and what is already put aside.
    private var reminderSignature: [String] {
        [personal, family].flatMap { session in
            session.envelopes.map { "\($0.id)\($0.nextDue.timeIntervalSince1970)\($0.size.minorUnits)\(session.envelopeBalance($0).minorUnits)" }
        }
    }

    /// Decided before anything is drawn, so the main screen never flashes behind the onboarding.
    private var needsOnboarding: Bool {
        guard !finishedOnboarding else { return false }
        // `-FolkiShowOnboarding YES` forces it for checks.
        if UserDefaults.standard.bool(forKey: "FolkiShowOnboarding") { return true }
        return !onboarded && !personal.isDemo
    }

    var body: some View {
        if needsOnboarding {
            OnboardingView(personal: personal, family: family) {
                onboarded = true
                onboardingStep = 0
                firstSpendTip = true
                withAnimation(FolkiMotion.standard) { finishedOnboarding = true }
            }
            .transition(.opacity)
        } else {
            TabView(selection: $tab) {
                Tab("Бюджет", systemImage: "wallet.bifold", value: TabID.budget) {
                    BudgetRootView(personal: personal, family: family, selectedDay: $selectedDay) { tab = .plan }
                }
                Tab("План", systemImage: "list.bullet.clipboard", value: TabID.plan) {
                    PlanTab(personal: personal, family: family)
                }
            }
            .tint(Color.folkiAccent)
            .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
            .onChange(of: reminderSignature) { reschedule() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { reschedule() } }
            .task { reschedule() }
        }
    }
}

extension FolkiRootView {
    private func reschedule() {
        let sessions = [personal, family]
        Task { await PlanReminders.reschedule(PlanSettings.load(), sessions: sessions) }
    }
}

/// Who is in the family, with a way to invite more. Lives in Settings.
struct FamilyMembersCard: View {
    let family: BudgetSession
    let manage: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(family.members.filter(\.isActive)) { member in
                HStack(spacing: 12) {
                    MemberAvatar(name: member.name)
                    Text(family.memberName(member.id)).font(.body.weight(.medium))
                    Spacer()
                    if member.id == family.authorID {
                        Text("Ты").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Button(action: manage) {
                Label("Пригласить", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(FolkiSoftButtonStyle())
        }.budgetCard()
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
