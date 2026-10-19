import SwiftUI
import FolkiDuoCore

/// Two rings: personal day outside, family day inside. Each shows what is left of today's guide.
struct FinancialRings: View {
    let personal: DailyBudgetSnapshot?
    let family: DailyBudgetSnapshot?
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var fractions: [Double] { [personal?.dayRingFraction ?? 0, family?.dayRingFraction ?? 0] }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let width = size * (compact ? 0.09 : 0.085)
            let gap = size * 0.02
            ZStack {
                FinancialRing(fraction: fractions[0], palette: .personal, lineWidth: width)
                FinancialRing(fraction: fractions[1], palette: .family, lineWidth: width)
                    .padding(width + gap)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.65), value: fractions)
    }
}

private struct FinancialRing: View, Animatable {
    var fraction: Double
    let palette: RingPalette
    let lineWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    private var progress: Double { max(0, min(1, fraction)) }
    nonisolated var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        ZStack {
            Circle().stroke(palette.start.opacity(colorScheme == .dark ? 0.22 : 0.16), lineWidth: lineWidth)
            if progress > 0 {
                Circle().trim(from: 0, to: progress)
                    .stroke(AngularGradient(colors: [palette.start, palette.end], center: .center,
                                            startAngle: .zero, endAngle: .degrees(360 * max(progress, 0.01))),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
    }
}

/// Rings with today's remainders in the center, then overspending notes and the month line.
struct BudgetRingsCard: View {
    let personal: DailyBudgetSnapshot?
    let family: DailyBudgetSnapshot?
    var isToday = true
    let reviewPlan: (BudgetScope) -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 40

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                FinancialRings(personal: personal, family: family)
                center.padding(48)
            }
            .aspectRatio(1, contentMode: .fit).frame(maxWidth: 300)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(isToday ? "Сегодня" : "Выбранный день"). Личный: \(spoken(personal)). Семейный: \(spoken(family)).")
            .accessibilityHint("Открыть расчёт")
            notes
            monthLine
        }.frame(maxWidth: .infinity)
    }

    private var center: some View {
        VStack(spacing: 4) {
            Text(isToday ? "Личный · сегодня" : "Личный · за день").font(.caption).foregroundStyle(.secondary)
            amount(personal?.todayRemaining, size: amountSize)
            Text(isToday ? "Семейный · сегодня" : "Семейный · за день").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            amount(family?.todayRemaining, size: amountSize * 0.55)
        }
        .lineLimit(1).minimumScaleFactor(0.5)
    }

    private func amount(_ money: Money?, size: CGFloat) -> some View {
        let whole = money?.roundedDownToWholeUnits
        return Text(whole.map(MoneyText.whole) ?? "—")
            .font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(whole.map { $0.minorUnits < 0 } == true ? Color.red : .primary)
            .contentTransition(.numericText(value: Double(whole?.minorUnits ?? 0)))
            .animation(.snappy, value: whole?.minorUnits)
    }

    @ViewBuilder private var notes: some View {
        let items = [(BudgetScope.personal, personal), (BudgetScope.family, family)].compactMap { scope, result in
            result.flatMap { note(for: scope, result: $0) }
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) { ForEach(items, id: \.0) { $0.1 } }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func note(for scope: BudgetScope, result: DailyBudgetSnapshot) -> (BudgetScope, AnyView)? {
        let name = scope == .personal ? "Личный" : "Семейный"
        if result.monthlyRemaining.minorUnits < 0 {
            let over = Money(minorUnits: -result.monthlyRemaining.minorUnits).roundedUpToWholeUnits
            return (scope, AnyView(HStack(alignment: .firstTextBaseline) {
                Text("\(name): месяц превышен на \(MoneyText.whole(over))").font(.subheadline)
                Spacer(minLength: 8)
                Button("Пересмотреть план") { reviewPlan(scope) }.font(.subheadline.weight(.semibold))
            }))
        }
        guard isToday, result.todayRemaining.minorUnits < 0, let next = result.futureAllocation else { return nil }
        return (scope, AnyView(Text("\(name): завтра ≈ \(MoneyText.whole(next.firstDayAmount.roundedDownToWholeUnits)) в день")
            .font(.subheadline).foregroundStyle(.secondary)))
    }

    private var monthLine: some View {
        HStack(spacing: 6) {
            Text("Месяц").foregroundStyle(.secondary)
            monthValue(personal, scope: .personal)
            Text("·").foregroundStyle(.tertiary)
            monthValue(family, scope: .family)
        }
        .font(.subheadline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
    }

    private func monthValue(_ result: DailyBudgetSnapshot?, scope: BudgetScope) -> some View {
        let value = result?.monthlyRemaining.roundedDownToWholeUnits
        return Text(value.map(MoneyText.whole) ?? "не настроен")
            .fontWeight(.semibold)
            .foregroundStyle(value.map { $0.minorUnits < 0 } == true ? Color.red : Color.budget(scope))
    }

    private func spoken(_ result: DailyBudgetSnapshot?) -> String {
        guard let result else { return "не настроен" }
        return "сегодня \(MoneyText.whole(result.todayRemaining.roundedDownToWholeUnits)), месяц \(MoneyText.whole(result.monthlyRemaining.roundedDownToWholeUnits))"
    }
}
