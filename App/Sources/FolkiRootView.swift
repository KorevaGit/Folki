import SwiftUI
import UIKit
import FolkiDuoCore

enum FolkiTab: Hashable { case summary, budget }

struct FolkiRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var selectedDay: Date?
    @State private var selection: FolkiTab = .budget
    @AppStorage("FolkiOnboarded") private var onboarded = false
    /// The step reached so far; survives a relaunch (for example after changing the app language).
    @AppStorage("FolkiOnboardingStep") private var onboardingStep = 0
    @State private var finishedOnboarding = false

    /// Decided before anything is drawn, so the main screen never flashes behind the onboarding.
    private var needsOnboarding: Bool {
        guard !finishedOnboarding else { return false }
        // `-FolkiShowOnboarding YES` forces it for checks.
        if UserDefaults.standard.bool(forKey: "FolkiShowOnboarding") { return true }
        return !onboarded && !personal.isDemo && (onboardingStep > 0 || personal.result == nil)
    }

    private var tabSelection: Binding<FolkiTab> {
        Binding(get: { selection }, set: select)
    }
    private func select(_ tab: FolkiTab) {
        if tab != selection { FolkiFeedback.selection() }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { selection = tab }
    }
    var body: some View {
        if needsOnboarding {
            OnboardingView(personal: personal, family: family) {
                onboarded = true
                onboardingStep = 0
                withAnimation(.smooth(duration: 0.4)) { finishedOnboarding = true }
            }
            .transition(.opacity)
        } else {
            tabs.transition(.opacity)
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab("Сводка", systemImage: "square.grid.2x2.fill", value: FolkiTab.summary) {
                FolkiSummaryView(personal: personal, family: family) { select(.budget) }
            }
            Tab("Бюджет", systemImage: "wallet.bifold", value: FolkiTab.budget) {
                BudgetRootView(personal: personal, family: family, selectedDay: $selectedDay)
            }
        }.tint(Color.folkiAccent)
    }
}

struct FolkiSummaryView: View {
    let personal: BudgetSession
    let family: BudgetSession
    let openBudget: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                summaryContent.folkiPagePadding(top: 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .background { FolkiBackground() }
            .navigationTitle("Сводка").toolbarTitleDisplayMode(.inlineLarge)
        }
    }

    private var summaryContent: some View {
        // Summary is always about today; browsing days lives on the Budget tab.
        let date = family.referenceDate
        return VStack(alignment: .leading, spacing: FolkiSpacing.item) {
            Button(action: openBudget) {
                budgetFavorite(personal: personal.overview(on: date).result, family: family.overview(on: date).result)
            }.buttonStyle(FolkiPressStyle()).accessibilityHint("Открыть вкладку «Бюджет»").folkiAppear(0)
            SummaryCards(personal: personal, family: family, date: date).folkiAppear(1)
        }
    }

    private func budgetFavorite(personal: DailyBudgetSnapshot?, family: DailyBudgetSnapshot?) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(spacing: 18))
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Бюджет", systemImage: "wallet.bifold.fill").foregroundStyle(Color.folkiAccent)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }.font(.headline)
            layout {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Личный · сегодня").font(.subheadline.weight(.semibold)).foregroundStyle(Color.budget(.personal))
                    Text(personal.map { MoneyText.whole($0.todayRemaining) } ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(personal.map { $0.todayRemaining.minorUnits < 0 } == true ? Color.red : .primary)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).fixedSize(horizontal: true, vertical: false)
                    Text("Семейный · сегодня").font(.subheadline.weight(.semibold)).foregroundStyle(Color.budget(.family))
                        .padding(.top, 6)
                    Text(family.map { MoneyText.whole($0.todayRemaining) } ?? "—")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(family.map { $0.todayRemaining.minorUnits < 0 } == true ? Color.red : .primary)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).fixedSize(horizontal: true, vertical: false)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                FinancialRings(personal: personal, family: family, compact: true)
                    .frame(width: 94, height: 94).accessibilityHidden(true)
            }
        }.budgetCard()
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
