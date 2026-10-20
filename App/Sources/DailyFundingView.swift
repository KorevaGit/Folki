import SwiftUI
import FolkiDuoCore

func distributionTitle(_ day: Int) -> String {
    day == 0 ? String(localized: "До конца месяца") : String(localized: "По \(day)-е число")
}

struct DistributionChoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var day: Int
    var apply: ((Int) throws -> Void)? = nil
    @State private var selection = 0
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Picker("Распределять деньги", selection: $selection) {
                    Text("До конца месяца").tag(0)
                    ForEach(1...31, id: \.self) { Text("По \($0)-е число").tag($0) }
                }.pickerStyle(.wheel)
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }.folkiFormLayout().navigationTitle("Распределение").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            do { try apply?(selection); day = selection; dismiss() }
                            catch { errorMessage = String(localized: "Не получилось изменить срок. Попробуй ещё раз.") }
                        }
                    }
                }.onAppear { selection = day }
        }.presentationDetents([.medium])
    }
}

/// First and subsequent deposits use the same short form.
struct DailyFundingView: View {
    let personal: BudgetSession
    let family: BudgetSession
    var initialScope: BudgetScope = .personal
    @Environment(\.dismiss) private var dismiss
    @State private var scope: BudgetScope = .personal
    @State private var amount = ""
    @State private var operationID = UUID()
    @State private var showingDistribution = false
    @State private var showingFullFinance = false
    @State private var errorMessage: String?
    private var session: BudgetSession { scope == .personal ? personal : family }
    private var money: Money? { (try? MoneyText.parse(amount)).flatMap { $0.minorUnits > 0 ? $0 : nil } }
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ScrollView {
                    VStack(spacing: 24) {
                        if family.household != nil {
                            FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: $scope,
                                options: BudgetScope.allCases.map { ($0.title, $0) })
                        }
                        Text("На повседневные траты").font(.headline).foregroundStyle(.secondary)
                        Text("\(amount.isEmpty ? "0" : amount) ₽")
                            .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.3).contentTransition(.numericText())
                        Button(distributionTitle(session.distributionDay)) { showingDistribution = true }
                            .font(.subheadline).foregroundStyle(Color.folkiAccent)
                        Button("Вести все финансы") {
                            do {
                                try session.ensureDailyPeriod(); session.fullFinanceEnabled = true; showingFullFinance = true
                            } catch { errorMessage = String(localized: "Не получилось открыть бюджет. Попробуй ещё раз.") }
                        }.font(.footnote).foregroundStyle(.secondary)
                        if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                    }.folkiPagePadding()
                }.scrollBounceBehavior(.basedOnSize)
                VStack(spacing: 12) {
                    AmountKeypad(text: $amount)
                    Button("Внести") {
                        guard let money else { return }
                        do { try session.addDailyFunds(money, operationID: operationID); FolkiFeedback.saved(); dismiss() }
                        catch { errorMessage = String(localized: "Не получилось внести деньги. Попробуй ещё раз.") }
                    }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true)).disabled(money == nil)
                }.padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.card)
            }.background { FolkiBackground() }.navigationTitle("Внести").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
                .sheet(isPresented: $showingDistribution) {
                    DistributionChoiceView(day: Binding(get: { session.distributionDay }, set: { session.distributionDay = $0 }),
                        apply: { try session.setDistributionDay($0) })
                }
                .sheet(isPresented: $showingFullFinance) { BudgetSetupView(session: session, editingCurrent: true) }
                .onAppear { scope = initialScope }
                .onChange(of: scope) { operationID = UUID(); errorMessage = nil }
        }
    }
}
