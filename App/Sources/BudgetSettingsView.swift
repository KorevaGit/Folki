import SwiftUI
import UIKit
import UserNotifications
import FolkiDuoCore

/// Settings: the budget's period and categories, the family, notifications and the app. No money moves here.
struct BudgetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @State private var scope: BudgetScope = .personal
    @State private var showingFamily = false
    @State private var showingDistribution = false
    @State private var reminderEditor: PlanEditorPart?
    @State private var reminders = PlanSettings.load()
    @State private var notificationsOff = false
    @Environment(\.scenePhase) private var scenePhase
    private var session: BudgetSession { scope == .personal ? personal : family }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FolkiSpacing.xs) {
                    if family.household != nil {
                        FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: $scope,
                            options: BudgetScope.allCases.map { ($0.title, $0) }, dots: [Color.folkiPersonal, Color.folkiFamily])
                            .padding(.bottom, FolkiSpacing.xs)
                    }
                    periodTile
                    HStack(spacing: FolkiSpacing.xs) {
                        familyTile
                        NavigationLink { CategoriesView(session: session).id(scope) } label: { categoriesTile }.buttonStyle(FolkiPressStyle())
                    }
                    remindersTile
                    HStack(spacing: FolkiSpacing.xs) {
                        iCloudTile
                        ShareLink(item: LedgerExport(personal: personal, family: family),
                                  preview: SharePreview(String(localized: "Траты Folki"))) {
                            smallTile(symbol: "tablecells", text: String(localized: "Выгрузить в CSV"), tint: Color.folkiAccent)
                        }.buttonStyle(FolkiPressStyle())
                    }
                    Text("Folki \(version)").font(FolkiFont.footnote).foregroundStyle(Color.folkiTertiary).padding(.top, FolkiSpacing.item)
                }
                .padding(.horizontal, FolkiSpacing.page).padding(.vertical, FolkiSpacing.xs)
            }
            .background { FolkiBackground() }
            .navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .sheet(isPresented: $showingDistribution) {
                DistributionChoiceView(current: session.periodRule, apply: { try session.setPeriodRule($0) })
            }
            .sheet(item: $reminderEditor, onDismiss: { reminders = PlanSettings.load() }) { part in
                PlanPartEditor(part: part, personal: personal, family: family)
            }
            .task { await checkNotifications() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await checkNotifications() } }
            }
            .sheet(isPresented: $showingFamily) { SharingView(session: family) }
        }
    }
    // MARK: Tiles — each shows its state, the words only name it.

    private var budgetColor: Color { Color.budget(scope) }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FolkiSpacing.xs) { content() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(FolkiSpacing.card)
            .folkiTileBackground()
            .foregroundStyle(Color.folkiInk)
    }

    /// The period as dates and a bar of the days gone; tap to change how it repeats.
    private var periodTile: some View {
        let period = session.household?.period
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        let total = period.map { max(1, session.calendar.dateComponents([.day], from: $0.start, to: $0.endExclusive).day ?? 1) } ?? 1
        let left = session.result?.remainingDays ?? total
        let gone = max(1, total - left + 1)
        return Button { showingDistribution = true } label: {
            tile {
                HStack {
                    Label(scope == .personal ? String(localized: "Только ты") : String(localized: "Видят все"),
                          systemImage: scope == .personal ? "lock.fill" : "person.2.fill")
                        .font(FolkiFont.tag).foregroundStyle(budgetColor)
                    Spacer()
                    Text("\(gone) из \(total) дн.").folkiText(.footnote).monospacedDigit()
                }
                if let period {
                    Text("\(period.start.formatted(style)) → \(period.endExclusive.addingTimeInterval(-1).formatted(style))")
                        .font(FolkiFont.moneyCard).monospacedDigit()
                } else {
                    Text("Не настроен").font(FolkiFont.section)
                }
                ProgressView(value: Double(gone), total: Double(total)).tint(scope == .personal ? Color.folkiPersonal : Color.folkiFamily)
                Text(periodRuleTitle(session.periodRule)).folkiText(.footnote)
            }
        }.buttonStyle(FolkiPressStyle())
    }

    private var familyTile: some View {
        // Before a family exists the tile still shows who is here: you, and a place for someone else.
        let source = family.household == nil ? personal : family
        let members = source.members.filter(\.isActive)
        return Button { showingFamily = true } label: {
            tile {
                HStack(spacing: -8) {
                    ForEach(members.prefix(3)) { member in
                        MemberAvatar(name: source.memberName(member.id)).scaleEffect(0.8).frame(width: 32, height: 32)
                    }
                    Image(systemName: "plus").font(FolkiFont.label).foregroundStyle(Color.budget(.family))
                        .frame(width: 32, height: 32)
                        .background(Circle().strokeBorder(Color.budget(.family), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                        .background(Circle().fill(Color.folkiTile))
                }.frame(height: 36)
                Text("Семья").font(FolkiFont.headline)
                Text(family.household == nil ? String(localized: "Позвать") : String(localized: "\(members.count) чел."))
                    .font(FolkiFont.footnote).foregroundStyle(Color.budget(.family))
            }
        }.buttonStyle(FolkiPressStyle())
    }

    private var categoriesTile: some View {
        let categories = session.catalog.selectable
        return tile {
            HStack(spacing: 4) {
                ForEach(categories.prefix(6)) { category in
                    Circle().fill(category.color.color).frame(width: 14, height: 14)
                }
            }.frame(height: 36)
            Text("Категории").font(FolkiFont.headline)
            Text("\(categories.count) включено").folkiText(.footnote).monospacedDigit()
        }
    }

    /// The month as a line: when Folki reminds to add money and when bills are due.
    private var remindersTile: some View {
        let incomeDays: [Int] = if case .monthly(let days) = reminders.income { days } else { [] }
        let paymentDays = reminders.paymentReminders ? Set((personal.payments + family.payments).map(\.dueDay)).sorted() : []
        return tile {
            Text("Напоминания").folkiText(.tag)
            GeometryReader { geometry in
                let step = (geometry.size.width - 22) / 30
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 3).padding(.horizontal, 11)
                    ForEach(paymentDays, id: \.self) { day in dayDot(day, color: Color.folkiWarning).offset(x: CGFloat(day - 1) * step) }
                    ForEach(incomeDays, id: \.self) { day in dayDot(day, color: Color.folkiAccent).offset(x: CGFloat(day - 1) * step) }
                }.frame(maxHeight: .infinity)
            }.frame(height: 28)
            Button { reminderEditor = .income } label: { legend(Color.folkiAccent, PlanText.incomeShort(reminders)) }
            Button { reminderEditor = .payments } label: { legend(Color.folkiWarning, PlanText.payments(reminders)) }
            if notificationsOff && reminders.usesNotifications {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Уведомления выключены — включить", systemImage: "bell.slash.fill")
                        .font(FolkiFont.tag).foregroundStyle(Color.folkiWarning)
                }
            }
        }.buttonStyle(.plain)
    }

    private func dayDot(_ day: Int, color: Color) -> some View {
        Text("\(day)").font(FolkiFont.dot).monospacedDigit().foregroundStyle(.white)
            .frame(width: 22, height: 22).background(color, in: Circle())
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: FolkiSpacing.xs) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(FolkiFont.caption).foregroundStyle(Color.folkiInk).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(FolkiFont.tag).foregroundStyle(Color.folkiTertiary)
        }.frame(minHeight: 32).contentShape(Rectangle())
    }

    private var iCloudTile: some View {
        let connected = personal.repository?.cloudIdentifier != nil
        return smallTile(symbol: connected ? "checkmark.icloud.fill" : "icloud.slash",
                         text: connected ? String(localized: "iCloud") : String(localized: "Только на iPhone"),
                         tint: connected ? Color.folkiAccent : .secondary)
            .accessibilityHint(personal.repository?.statusText ?? "")
    }

    private func smallTile(symbol: String, text: String, tint: Color) -> some View {
        VStack(spacing: FolkiSpacing.xs) {
            Image(systemName: symbol).font(FolkiFont.icon)
            Text(text).font(FolkiFont.label).multilineTextAlignment(.center)
        }
        .foregroundStyle(tint).frame(maxWidth: .infinity, minHeight: 72).padding(.vertical, FolkiSpacing.xs)
        .folkiTileBackground()
    }

    private func checkNotifications() async {
        notificationsOff = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }
}

/// Every record of both budgets as a CSV file for Excel or Numbers; the file is written only when shared.
struct LedgerExport: Transferable {
    let text: String

    @MainActor init(personal: BudgetSession, family: BudgetSession) {
        let rows = [personal, family].filter { $0.household != nil }.flatMap { session in
            session.historyRecords.filter { !$0.transaction.isDeleted }.map { record in
                let kind = record.transaction.kind
                let outgoing = [.expense, .reserveAllocation, .contributionOut].contains(kind)
                let amount = record.transaction.amount
                return LedgerCSV.Row(date: record.transaction.date, budget: session.scope.title, kind: Self.title(of: kind),
                    // Only spending has a category; an income's stored "Другое" would mislead.
                    category: [.expense, .refund].contains(kind) ? session.catalog.category(for: record.categoryID).name : "",
                    amount: outgoing ? Money(minorUnits: -amount.minorUnits, currency: amount.currency) : amount,
                    author: session.memberName(record.transaction.payerID), title: record.title)
            }
        }
        text = LedgerCSV.make(header: [String(localized: "Дата"), String(localized: "Бюджет"), String(localized: "Тип"),
                                       String(localized: "Категория"), String(localized: "Сумма"), String(localized: "Кто"),
                                       String(localized: "Описание")],
                              rows: rows, timeZone: personal.calendar.timeZone)
    }

    private static func title(of kind: TransactionKind) -> String {
        switch kind {
        case .expense: String(localized: "Трата")
        case .refund: String(localized: "Возврат")
        case .income: String(localized: "Поступление")
        case .reserveAllocation: String(localized: "В конверт")
        case .reserveRelease: String(localized: "Из конверта")
        case .contributionOut: String(localized: "Вклад в семью")
        case .contributionIn: String(localized: "Вклад от участника")
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Folki.csv")
            try Data(export.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
