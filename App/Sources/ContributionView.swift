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
                        .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.3).frame(maxWidth: .infinity)
                    if let available {
                        Text("Можно перевести до \(MoneyText.whole(available))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let money, let personalBefore = personal.result, let familyBefore = family.result,
                       let personalAfter = personal.previewTransfer(money, kind: .contributionOut),
                       let familyAfter = family.previewTransfer(money, kind: .contributionIn) {
                        VStack(spacing: 16) {
                            ImpactLines(before: personalBefore, after: personalAfter, label: "Личный после перевода")
                            Divider()
                            ImpactLines(before: familyBefore, after: familyAfter, label: "Семейный после перевода")
                        }.budgetCard()
                    } else if !amount.isEmpty {
                        Text("Введи сумму в пределах свободного остатка личного бюджета.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Это перевод твоих денег в общий бюджет, а не новый доход или трата. Семья увидит взнос; личные суммы останутся приватными.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                }.padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
            } keypad: {
                VStack(spacing: 12) {
                    AmountKeypad(text: $amount)
                    Button(action: transfer) {
                        Text("Перевести в семейный").font(.headline)
                            .frame(maxWidth: .infinity).frame(minHeight: 60).foregroundStyle(.white)
                            .background(Color.folkiAccent, in: Capsule())
                    }.buttonStyle(.plain).disabled(money == nil)
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
        catch BudgetError.insufficientReserve { errorMessage = "В личном бюджете недостаточно свободных денег." }
        catch { errorMessage = "Не удалось перевести. Сумма осталась здесь; попробуй снова." }
    }
}
