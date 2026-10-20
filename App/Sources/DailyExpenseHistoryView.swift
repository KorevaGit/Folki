import SwiftUI
import FolkiDuoCore

/// Both budgets share one day timeline. Funding source never hides a payment.
struct DailyExpenseHistoryView: View {
    let personal: BudgetSession
    let family: BudgetSession
    let personalDay: BudgetDayOverview
    let familyDay: BudgetDayOverview
    @Binding var atTop: Bool
    let edit: (LedgerRecord, BudgetScope) -> Void

    private struct Entry: Identifiable {
        let record: LedgerRecord
        let session: BudgetSession
        var id: String { session.scope.rawValue + record.id.uuidString }
    }
    private var entries: [Entry] {
        [(personal, personalDay), (family, familyDay)].flatMap { session, day in
            day.records.filter {
                !$0.transaction.isDeleted && [.expense, .refund].contains($0.transaction.kind)
            }.map { Entry(record: $0, session: session) }
        }.sorted {
            if $0.record.transaction.date != $1.record.transaction.date {
                return $0.record.transaction.date > $1.record.transaction.date
            }
            return $0.id < $1.id
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Траты за день").font(.system(.title2, design: .rounded, weight: .bold))
                    .padding(.bottom, 20)
                if personalDay.errorMessage != nil || familyDay.errorMessage != nil {
                    FolkiErrorMessage(message: String(localized: "Не получилось загрузить траты за день. Попробуй ещё раз."))
                }
                if entries.isEmpty {
                    ContentUnavailableView("Трат пока нет", systemImage: "basket")
                        .frame(maxWidth: .infinity).padding(.top, 28)
                } else {
                    ForEach(entries) { entry in
                        if entry.session.isEditable(entry.record) {
                            Button { edit(entry.record, entry.session.scope) } label: { row(entry) }
                                .buttonStyle(FolkiPressStyle())
                        } else { row(entry) }
                        Divider().padding(.leading, 54)
                    }
                }
            }.padding(.horizontal, FolkiSpacing.page).padding(.bottom, 28)
                .frame(maxWidth: FolkiSpacing.maxWidth).frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height <= geometry.containerSize.height ||
                geometry.contentOffset.y + geometry.contentInsets.top <= 1
        } action: { _, value in atTop = value }
        .onAppear { atTop = true }
    }

    private func row(_ entry: Entry) -> some View {
        let record = entry.record, session = entry.session
        let category = session.category(for: record)
        let reserve: ProtectedReserve? = {
            guard case .reserve(let id) = record.transaction.funding else { return nil }
            // A past day's reserve may belong to an older period; keep the source visible.
            return session.household?.reserves.first { $0.id == id }
        }()
        return HStack(spacing: 12) {
            if let category { CategoryIcon(category: category) }
            else { CategoryIcon(symbol: "basket", color: .secondary) }
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title.isEmpty ? (category?.name ?? String(localized: "Другое")) : record.title)
                    .foregroundStyle(Color.folkiInk)
                HStack(spacing: 6) {
                    if family.household != nil { Text(session.scope.title).foregroundStyle(Color.budget(session.scope)) }
                    if case .reserve = record.transaction.funding {
                        Label(reserve?.name ?? String(localized: "Конверт"), systemImage: "envelope")
                    } else if !record.title.isEmpty, let category { Text(category.name) }
                }.font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text((record.transaction.kind == .refund ? "+" : "−") + MoneyText.string(record.transaction.amount))
                .fontWeight(.semibold).monospacedDigit().foregroundStyle(Color.folkiInk)
                .lineLimit(1).minimumScaleFactor(0.65).layoutPriority(1)
        }.font(.subheadline).padding(.vertical, 14).contentShape(Rectangle())
    }
}
