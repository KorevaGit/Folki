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
    @State private var showsOnboarding = false

    private var tabSelection: Binding<FolkiTab> {
        Binding(get: { selection }, set: select)
    }
    private func select(_ tab: FolkiTab) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { selection = tab }
    }
    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Сводка", systemImage: "square.grid.2x2.fill", value: FolkiTab.summary) {
                FolkiSummaryView(personal: personal, family: family, selectedDay: $selectedDay) { select(.budget) }
            }
            Tab("Бюджет", systemImage: "wallet.bifold", value: FolkiTab.budget) {
                BudgetRootView(personal: personal, family: family, selectedDay: $selectedDay)
            }
        }.tint(Color.folkiAccent)
        .onAppear {
            // New users only; `-FolkiShowOnboarding YES` forces it for checks.
            let forced = UserDefaults.standard.bool(forKey: "FolkiShowOnboarding")
            showsOnboarding = forced || (!onboarded && personal.result == nil && !personal.isDemo)
        }
        .fullScreenCover(isPresented: $showsOnboarding) {
            OnboardingView(personal: personal, family: family) {
                onboarded = true
                showsOnboarding = false
            }
        }
    }
}

struct FolkiSummaryView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @Binding var selectedDay: Date?
    let openBudget: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            GeometryReader { page in
                if page.size.height < 520 || dynamicTypeSize.isAccessibilitySize {
                    ScrollView {
                        VStack(spacing: FolkiSpacing.item) {
                            weekCalendar
                            summaryContent
                        }.folkiPagePadding(top: 4)
                    }.scrollBounceBehavior(.basedOnSize)
                } else {
                    VStack(spacing: FolkiSpacing.item) {
                        weekCalendar.padding(.horizontal, FolkiSpacing.page)
                        ScrollView {
                            summaryContent.padding(.horizontal, FolkiSpacing.page).padding(.bottom, 90)
                        }.scrollBounceBehavior(.basedOnSize)
                    }.padding(.top, 4)
                        .frame(maxWidth: FolkiSpacing.maxWidth).frame(maxWidth: .infinity)
                }
            }
            .background { FolkiBackground() }
            .navigationTitle("Сводка").toolbarTitleDisplayMode(.inlineLarge)
        }
    }

    private var weekCalendar: some View {
        BudgetWeekCalendar(selection: $selectedDay, today: family.referenceDate, calendar: family.calendar) { day in
            (personal.overview(on: day).result?.dayRingFraction, family.overview(on: day).result?.dayRingFraction)
        }
    }

    private var summaryContent: some View {
        let date = selectedDay ?? family.referenceDate
        return VStack(alignment: .leading, spacing: FolkiSpacing.item) {
            Button(action: openBudget) {
                budgetFavorite(personal: personal.overview(on: date).result, family: family.overview(on: date).result)
            }.buttonStyle(.plain).accessibilityHint("Открыть вкладку «Бюджет»")
            SummaryCards(personal: personal, family: family, date: date)
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
