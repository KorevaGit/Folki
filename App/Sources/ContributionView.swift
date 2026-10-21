import SwiftUI
import FolkiDuoCore

/// Moves money from the personal budget into the family one. Neither side counts as spending.
struct ContributionView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @State private var linkID = UUID()
    @State private var amount = ""
    @State private var errorMessage: String?
    private var available: Money? { personal.result?.monthlyRemaining }
    private var money: Money? {
        guard let money = try? MoneyText.parse(amount), money.minorUnits > 0,
              let available, money.minorUnits <= available.minorUnits else { return nil }
        return money
    }

    var body: some View {
        NavigationStack {
            FolkiEntryLayout { _ in
                VStack(spacing: 20) {
                    Label("Из личного в семейный", systemImage: "arrow.right")
                        .font(.headline).foregroundStyle(Color.folkiAccent)
                    Text("\(amount.isEmpty ? "0" : amount) ₽")
                        .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(amount.isEmpty ? .tertiary : .primary)
                        .lineLimit(1).minimumScaleFactor(0.3).frame(maxWidth: .infinity)
                        .contentTransition(.numericText()).animation(FolkiMotion.quick, value: amount)
                    if let available {
                        Text("Можно перевести до \(MoneyText.whole(available))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    // Both budgets are always visible, so the effect of the amount shows as it is typed.
                    if let personalBefore = personal.result, let familyBefore = family.result {
                        VStack(spacing: 16) {
                            ImpactLines(before: personalBefore,
                                        after: money.flatMap { personal.previewTransfer($0, kind: .contributionOut) },
                                        label: String(localized: "Личный"))
                            Divider()
                            ImpactLines(before: familyBefore,
                                        after: money.flatMap { family.previewTransfer($0, kind: .contributionIn) },
                                        label: String(localized: "Семейный"))
                        }.budgetCard()
                    }
                    if !amount.isEmpty && money == nil {
                        Text("Больше, чем свободно в личном бюджете").font(.footnote).foregroundStyle(Color.folkiOver)
                    }
                    Text("Семья увидит взнос, а твой личный бюджет — нет 🤫")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                }.padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
            } keypad: {
                VStack(spacing: 12) {
                    AmountKeypad(text: $amount)
                    Button(action: transfer) {
                        Text("Перевести в семейный").font(.system(.title3, design: .rounded, weight: .bold))
                            .frame(maxWidth: .infinity).frame(minHeight: 60).foregroundStyle(.white)
                            .glassEffect(.regular.tint(Color.folkiAccent.opacity(money == nil ? 0.35 : 1)).interactive(), in: Capsule())
                    }.buttonStyle(FolkiPressStyle()).disabled(money == nil)
                }.padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
            }
            .background { FolkiBackground() }
            .navigationTitle("Взнос").toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }.tint(Color.folkiInk)
                }
            }
        }.tint(Color.folkiAccent)
    }

    private func transfer() {
        guard let money else { return }
        do { try personal.contribute(money, to: family, linkID: linkID); FolkiFeedback.saved(); dismiss() }
        catch BudgetError.insufficientReserve { errorMessage = String(localized: "В личном бюджете недостаточно свободных денег.") }
        catch { errorMessage = String(localized: "Не получилось перевести. Сумма осталась здесь; попробуй снова.") }
    }
}
