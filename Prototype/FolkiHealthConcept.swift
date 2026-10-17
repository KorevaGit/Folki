import SwiftUI

// A native UI prototype. Add this file to an iOS target, then open the Preview.
// Demo data is held in memory; Core Data and CloudKit are not connected here.
@available(iOS 26.0, *)
struct FolkiHealthConcept: View {
    @State private var selectedTab = 0
    @State private var transactions = DemoTransaction.initial
    @State private var editorPresented = false
    @State private var selectedDetail: DemoDetail?

    private var spent: Int64 { transactions.reduce(0) { $0 + $1.kopecks } }
    private let guide: Int64 = 277_000
    private let startBalance: Int64 = 4_155_000

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Сводка", systemImage: "square.grid.2x2.fill", value: 0) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Button { selectedDetail = .daily } label: { dailyCard }
                                .buttonStyle(.plain)
                            Button { selectedDetail = .forecast } label: { forecastCard }
                                .buttonStyle(.plain)
                            sectionTitle("Накопления")
                            Button { selectedDetail = .goal } label: { goalCard }
                                .buttonStyle(.plain)
                            HStack {
                                sectionTitle("Награды")
                                Spacer()
                                Button("Показать все") { selectedTab = 2 }
                                    .font(.subheadline)
                            }
                            Button { selectedDetail = .award(DemoAward.all[0]) } label: {
                                HStack(spacing: 14) {
                                    DemoMedal(symbol: "person.2.fill")
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Планируем вдвоём").font(.headline)
                                        Text("Получено · 12 октября")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }.demoCard()
                            }.buttonStyle(.plain)
                            sectionTitle("Последние расходы")
                            VStack(spacing: 0) {
                                ForEach(transactions.suffix(3).reversed()) { transaction in
                                    transactionRow(transaction)
                                    if transaction.id != transactions.suffix(3).first?.id { Divider() }
                                }
                            }.demoCard()
                            Text("Folki · демонстрационные данные")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical)
                        }.padding(.horizontal, 16).padding(.bottom, 16)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .navigationTitle("Сводка")
                    .toolbar { addToolbar }
                }
            }
            Tab("История", systemImage: "list.bullet", value: 1) {
                NavigationStack {
                    List {
                        Section("Сегодня · \(demoMoney(spent))") {
                            ForEach(transactions.reversed()) { transactionRow($0) }
                        }
                    }.navigationTitle("История").toolbar { addToolbar }
                }
            }
            Tab("Награды", systemImage: "medal.fill", value: 2) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Маленькие шаги к общим планам.")
                                .foregroundStyle(.secondary)
                            Text("Получено · 3").font(.title2.bold())
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(DemoAward.all) { award in
                                    Button { selectedDetail = .award(award) } label: {
                                        VStack(spacing: 12) {
                                            DemoMedal(symbol: award.symbol, locked: award.locked)
                                            Text(award.name).font(.subheadline.weight(.semibold))
                                            Text(award.subtitle).font(.caption).foregroundStyle(.secondary)
                                            if award.locked { ProgressView(value: 5, total: 7).tint(.orange) }
                                            Spacer(minLength: 0)
                                        }
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity, minHeight: 170)
                                        .demoCard()
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.padding(16)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .navigationTitle("Награды")
                }
            }
        }
        .tint(.primary)
        .sheet(isPresented: $editorPresented) {
            DemoExpenseEditor(spent: spent, guide: guide, startBalance: startBalance) {
                transactions.append($0)
            }
        }
        .sheet(item: $selectedDetail) { detail in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(detailTitle(detail)).font(.title.bold())
                        Text(detailText(detail)).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { selectedDetail = nil }
                } }
            }.presentationDetents([.medium, .large])
        }
    }

    @ToolbarContentBuilder private var addToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Добавить расход", systemImage: "plus") { editorPresented = true }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title2.bold()).padding(.top, 14)
    }

    private var dailyCard: some View {
        VStack(spacing: 16) {
            ZStack {
                DemoConcentricBudgetRings(
                    day: Double(guide - spent) / Double(guide),
                    month: Double(startBalance - spent) / 12_000_000
                )
                VStack(spacing: 7) {
                    Text(spent <= guide ? "Сегодня осталось" : "Сегодня сверх плана")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(demoMoney(abs(guide - spent)))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    Text("на двоих").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 60)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
            budgetLegend("Сегодня", color: .orange, remaining: max(0, guide - spent), total: guide)
            budgetLegend(startBalance >= spent ? "Октябрь" : "Октябрь · дефицит", color: .purple,
                         remaining: abs(startBalance - spent), total: 12_000_000)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
    }

    private func budgetLegend(_ title: String, color: Color, remaining: Int64, total: Int64) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                Text(demoMoney(remaining)).fontWeight(.semibold)
                Text(" / \(demoMoney(total))").foregroundStyle(.secondary)
            }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.font(.caption)
    }

    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeading("Следующие дни", symbol: "calendar")
            Text("≈\(demoMoney((startBalance - spent) / 14)) / день")
                .font(.title2.bold()).monospacedDigit()
            Text("Если сегодня больше не тратить · 14 дней")
                .font(.caption).foregroundStyle(.secondary)
        }.demoCard()
    }

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeading("Общая цель", symbol: "flag.fill")
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Путешествие").font(.headline)
                    Text("48 000 ₽").font(.title2.bold())
                    Text("из 80 000 ₽").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                DemoBudgetRing(fraction: 0.6).frame(width: 66, height: 66)
            }
        }.demoCard()
    }

    private func cardHeading(_ title: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(.orange)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.font(.subheadline.weight(.semibold))
    }

    private func transactionRow(_ value: DemoTransaction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: value.symbol).frame(width: 25)
            VStack(alignment: .leading, spacing: 4) {
                Text(value.name)
                Text(value.payer).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("−\(demoMoney(value.kopecks))").monospacedDigit()
        }.font(.subheadline).padding(.vertical, 10)
    }

    private func detailTitle(_ detail: DemoDetail) -> String {
        switch detail {
        case .daily: "Дневной бюджет"
        case .forecast: "Следующие дни"
        case .goal: "Путешествие"
        case .award(let value): value.name
        }
    }

    private func detailText(_ detail: DemoDetail) -> String {
        switch detail {
        case .daily: "Внешнее оранжевое кольцо — остаток дня из 2 770 ₽. Внутреннее фиолетовое — остаток месячного свободного плана из 120 000 ₽. До сегодняшнего дня потрачено 78 450 ₽; сегодня — \(demoMoney(spent)). Обязательные платежи и накопления исключены из свободного плана. При превышении кольцо пустое, а дефицит указан отдельно."
        case .forecast: "Осталось \(demoMoney(startBalance - spent)) на следующие 14 дней. Прогноз предполагает, что сегодня больше не будет трат."
        case .goal: "Накоплено 48 000 ₽ из 80 000 ₽. Маша — 26 000 ₽, Саша — 22 000 ₽. Накопления учитываются отдельно от повседневного бюджета."
        case .award(let value): value.detail
        }
    }
}

private struct DemoConcentricBudgetRings: View {
    let day: Double
    let month: Double

    var body: some View {
        ZStack {
            budgetArc(day, color: .orange, lineWidth: 17)
            budgetArc(month, color: .purple, lineWidth: 16).padding(26)
        }
        .padding(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Остаток дневного и месячного бюджета")
        .accessibilityValue("Сегодня \(percent(day)) процентов, месяц \(percent(month)) процентов")
    }

    private func percent(_ value: Double) -> Int {
        Int((max(0, min(1, value)) * 100).rounded())
    }

    private func budgetArc(_ value: Double, color: Color, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.14), lineWidth: lineWidth)
            if value > 0 {
                Circle().trim(from: 0, to: min(1, value))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

private struct DemoBudgetRing: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 8)
            if fraction > 0 {
                Circle().trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))%")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .padding(5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Доля остатка или накопления")
        .accessibilityValue("\(Int((max(0, min(1, fraction)) * 100).rounded())) процентов")
    }
}

private struct DemoMedal: View {
    let symbol: String
    var locked = false
    var body: some View {
        Image(systemName: symbol)
            .font(.title2.weight(.semibold))
            .foregroundStyle(locked ? Color.secondary : Color.orange)
            .frame(width: 62, height: 62)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
            .overlay { Circle().stroke(locked ? Color.secondary.opacity(0.3) : Color.orange.opacity(0.7), lineWidth: 2) }
            .accessibilityHidden(true)
    }
}

private struct DemoTransaction: Identifiable {
    let id = UUID()
    var name: String
    var payer: String
    var kopecks: Int64
    var symbol: String
    static let initial = [
        DemoTransaction(name: "Продукты к ужину", payer: "Маша", kopecks: 105_000, symbol: "basket.fill"),
        DemoTransaction(name: "Кофе и прогулка", payer: "Саша", kopecks: 62_000, symbol: "cup.and.saucer.fill")
    ]
}

private struct DemoAward: Identifiable {
    var id: String { name }
    let name: String
    let symbol: String
    let subtitle: String
    let detail: String
    var locked = false
    static let all = [
        DemoAward(name: "Планируем вдвоём", symbol: "person.2.fill", subtitle: "Оба участвуют в бюджете", detail: "Маша и Саша сохранили записи в общий бюджет. Награда общая, без сравнения сумм."),
        DemoAward(name: "Первый шаг", symbol: "flag.fill", subtitle: "5 000 ₽ к общей цели", detail: "Вы отложили первые 5 000 ₽ на общую цель."),
        DemoAward(name: "Ясный план", symbol: "checkmark.seal.fill", subtitle: "Платежи учтены", detail: "Вы проверили и подтвердили список обязательных платежей."),
        DemoAward(name: "Неделя в ритме", symbol: "calendar.badge.checkmark", subtitle: "5 из 7 дней", detail: "Проверьте дневной план в семь разных дней недели. Покупки и перерасход не отменяют прогресс.", locked: true)
    ]
}

private enum DemoDetail: Identifiable {
    case daily, forecast, goal, award(DemoAward)
    var id: String {
        switch self {
        case .daily: "daily"
        case .forecast: "forecast"
        case .goal: "goal"
        case .award(let award): "award-\(award.id)"
        }
    }
}

private struct DemoExpenseEditor: View {
    @Environment(\.dismiss) private var dismiss
    let spent: Int64
    let guide: Int64
    let startBalance: Int64
    let save: (DemoTransaction) -> Void
    @State private var amount = ""
    @State private var name = ""
    @State private var payer = "Маша"

    private var kopecks: Int64? {
        guard let decimal = Decimal(string: amount.replacingOccurrences(of: ",", with: ".")),
              decimal > 0, decimal <= 10_000_000 else { return nil }
        let scaled = decimal * 100
        let value = NSDecimalNumber(decimal: scaled).int64Value
        return Decimal(value) == scaled ? value : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Сумма, ₽") {
                    TextField("0", text: $amount).keyboardType(.decimalPad).font(.largeTitle.bold())
                }
                Section {
                    TextField("Название", text: $name)
                    Picker("Оплатил", selection: $payer) {
                        Text("Маша").tag("Маша")
                        Text("Саша").tag("Саша")
                    }
                }
                if let amount = kopecks {
                    Section("После записи") {
                        LabeledContent("Сегодня сверх ориентира", value: demoMoney(max(0, spent + amount - guide)))
                        LabeledContent("Далее в день", value: "≈\(demoMoney((startBalance - spent - amount) / 14))")
                        Text("На 14 дней, если сегодня больше не тратить.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Записать расход") {
                        guard let value = kopecks else { return }
                        save(DemoTransaction(name: name.trimmingCharacters(in: .whitespacesAndNewlines), payer: payer, kopecks: value, symbol: "receipt.fill"))
                        dismiss()
                    }.disabled(kopecks == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Демонстрационные данные · без синхронизации")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Новый расход").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            } }
        }
    }
}

private func demoMoney(_ kopecks: Int64) -> String {
    let number = NSDecimalNumber(decimal: Decimal(kopecks) / 100)
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return "\(formatter.string(from: number) ?? "0") ₽"
}

private extension View {
    func demoCard() -> some View {
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

@available(iOS 26.0, *)
#Preview("Folki · Health-inspired") {
    FolkiHealthConcept().preferredColorScheme(.dark)
}
