import SwiftUI
import FolkiDuoCore

private enum BudgetSheet: String, Identifiable {
    case setup, expense, daily, forecast
    var id: String { rawValue }
}

struct BudgetRootView: View {
    @Bindable var session: BudgetSession
    @State private var tab = 0
    @State private var sheet: BudgetSheet?

    var body: some View {
        TabView(selection: $tab) {
            Tab("Сводка", systemImage: "square.grid.2x2.fill", value: 0) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let result = session.result {
                                Button { sheet = .daily } label: { BudgetRingsView(result: result) }
                                    .buttonStyle(.plain)
                                Button { sheet = .forecast } label: { forecast(result) }
                                    .buttonStyle(.plain)
                                #if FOLKI_DEMO
                                DemoHighlightsView { tab = 2 }
                                #endif
                                sectionTitle("Последние расходы")
                                if session.records.isEmpty {
                                    Text("Здесь появятся ваши расходы.")
                                        .foregroundStyle(.secondary).padding(.vertical)
                                } else {
                                    VStack(spacing: 0) {
                                        ForEach(session.records.suffix(3).reversed()) { record in
                                            LedgerRow(record: record, payer: session.payerName(for: record))
                                            if record.id != session.records.suffix(3).first?.id { Divider() }
                                        }
                                    }.budgetCard()
                                }
                            } else {
                                ContentUnavailableView {
                                    Label("Ваш общий бюджет", systemImage: "wallet.bifold")
                                } description: {
                                    Text(session.errorMessage ?? "Укажите свободные деньги и план месяца — посчитаем ориентир на сегодня.")
                                } actions: {
                                    Button { sheet = .setup } label: {
                                        Text("Настроить бюджет")
                                            .foregroundStyle(Color(uiColor: .systemBackground))
                                    }.buttonStyle(.borderedProminent)
                                }
                            }
                            Text(session.isDemo ? "Демонстрационные данные · 17 октября" : "Локальный прототип · после закрытия данные сбросятся")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical)
                        }.padding(.horizontal, 16).padding(.bottom, 16)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .navigationTitle("Сводка")
                    .toolbar { expenseToolbar }
                }
            }
            Tab("История", systemImage: "list.bullet", value: 1) {
                NavigationStack {
                    List {
                        ForEach(session.records.reversed()) { record in
                            LedgerRow(record: record, payer: session.payerName(for: record))
                        }
                    }
                    .overlay {
                        if session.records.isEmpty {
                            ContentUnavailableView("Расходов пока нет", systemImage: "list.bullet.rectangle",
                                                   description: Text("Добавьте первый расход кнопкой сверху."))
                        }
                    }
                    .navigationTitle("История")
                    .toolbar { expenseToolbar }
                }
            }
            Tab("Награды", systemImage: "medal.fill", value: 2) {
                NavigationStack {
                    #if FOLKI_DEMO
                    DemoAwardsView()
                    #else
                    ContentUnavailableView("Ваш прогресс вместе", systemImage: "medal",
                                           description: Text("Достижения появятся после подключения целей и совместного бюджета."))
                        .navigationTitle("Награды")
                    #endif
                }
            }
        }
        .tint(.primary)
        .sheet(item: $sheet) { destination in
            switch destination {
            case .setup: BudgetSetupView(session: session)
            case .expense: ExpenseEditorView(session: session)
            case .daily, .forecast:
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let result = session.result {
                                Text(destination == .daily ? "День и месяц" : "Следующие дни").font(.title.bold())
                                if destination == .daily {
                                    Text("Внешнее оранжевое кольцо — остаток дня. Внутреннее фиолетовое — остаток свободного месячного плана.")
                                    Text("Ориентир дня: \(MoneyText.string(result.todayGuide)). Потрачено: \(MoneyText.string(result.todayNetSpending)).")
                                } else {
                                    Text("Свободно \(MoneyText.string(result.monthlyRemaining)). Прогноз предполагает, что сегодня больше не будет расходов.")
                                    Text("Распределяем каждую копейку: первые дни могут отличаться на одну копейку от следующих.")
                                }
                            }
                        }.foregroundStyle(.secondary).padding(24)
                    }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { sheet = nil } } }
                }.presentationDetents([.medium, .large])
            }
        }
    }

    @ToolbarContentBuilder private var expenseToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Добавить расход", systemImage: "plus") { sheet = session.result == nil ? .setup : .expense }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.title2.bold()).padding(.top, 14)
    }

    private func forecast(_ result: DailyBudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Следующие дни", systemImage: "calendar").foregroundStyle(.orange)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.font(.subheadline.weight(.semibold))
            if result.monthlyRemaining.minorUnits < 0 {
                Text("Свободный бюджет закончился").font(.headline)
                Text("Пересмотрите расходы или план.").font(.caption).foregroundStyle(.secondary)
            } else if let future = result.futureAllocation {
                Text("≈\(MoneyText.string(future.firstDayAmount)) / день")
                    .font(.title2.bold()).monospacedDigit()
                Text("Если сегодня больше не тратить · \(future.days) дн.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Последний день периода").font(.headline)
                Text("Сегодня доступен оставшийся бюджет.").font(.caption).foregroundStyle(.secondary)
            }
        }.budgetCard()
    }
}

private struct BudgetRingsView: View {
    let result: DailyBudgetSnapshot
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ZStack {
                    arc(result.dayRingFraction, color: .orange, width: 17)
                    arc(result.monthRingFraction, color: .purple, width: 16).padding(26)
                }.padding(12).accessibilityHidden(true)
                VStack(spacing: 7) {
                    Text(result.todayRemaining.minorUnits >= 0 ? "Сегодня осталось" : "Сегодня сверх плана")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(MoneyText.string(result.todayRemaining.minorUnits >= 0 ? result.todayRemaining : result.todayOverspending))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    Text("на двоих").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 60)
            }
            .aspectRatio(1, contentMode: .fit).frame(maxWidth: 320)
            legend("Сегодня", color: .orange, remaining: result.todayRemaining.nonnegative, plan: result.todayGuide)
            legend("Месяц", color: .purple, remaining: result.monthlyRemaining, plan: result.monthlyPlan)
        }.frame(maxWidth: .infinity).padding(.bottom, 16)
    }

    private func arc(_ value: Double, color: Color, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.14), lineWidth: width)
            if value > 0 {
                Circle().trim(from: 0, to: value)
                    .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    private func legend(_ title: LocalizedStringKey, color: Color, remaining: Money, plan: Money) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                Text(MoneyText.string(remaining)).fontWeight(.semibold)
                Text(" / \(MoneyText.string(plan))").foregroundStyle(.secondary)
            }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }.font(.caption)
    }
}

struct LedgerRow: View {
    let record: LedgerRecord
    let payer: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                Text(payer).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("−\(MoneyText.string(record.transaction.amount))").monospacedDigit()
        }.font(.subheadline).padding(.vertical, 10)
    }
}

extension View {
    func budgetCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
