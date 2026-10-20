import SwiftUI
import UIKit
import FolkiDuoCore

/// Two rings: personal day outside, family day inside. Each shows what is left of today's guide.
struct FinancialRings: View {
    nonisolated static let aspectRatio: CGFloat = 1
    let personal: DailyBudgetSnapshot?
    let family: DailyBudgetSnapshot?
    var compact = false
    var showsMonth = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Rings fill up once when the screen first appears.
    @State private var appeared = false
    private var fractions: [Double] {
        [personal, family].map { result in
            guard let result, appeared || reduceMotion else { return 0 }
            guard showsMonth else { return result.dayRingFraction }
            guard result.monthlyPlan.minorUnits > 0 else { return 0 }
            return max(0, min(1, Double(result.monthlyRemaining.minorUnits) / Double(result.monthlyPlan.minorUnits)))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let width = size * 0.09
            let gap = size * 0.018
            ZStack {
                FinancialRing(fraction: fractions[0], palette: .personal, lineWidth: width)
                FinancialRing(fraction: fractions[1], palette: .family, lineWidth: width)
                    .padding(width + gap)
            }
            .frame(width: size, height: size)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .animation(reduceMotion ? nil : (appeared ? .spring(duration: 0.5, bounce: 0.1) : nil), value: fractions)
        .onAppear {
            guard !appeared else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.9, bounce: 0.15).delay(0.1)) { appeared = true }
        }
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
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let radius = (diameter - lineWidth) / 2
            let angle = 2 * Double.pi * progress - Double.pi / 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let capDistance = 2 * radius * sin(Double.pi * (1 - progress))
            ZStack {
                Circle().stroke(palette.start.opacity(colorScheme == .dark ? 0.22 : 0.16), lineWidth: lineWidth)
                if progress > 0 {
                    Circle().trim(from: 0, to: progress)
                        .stroke(palette.start,
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        // A round cap otherwise remains a full-size dot until the last
                        // animation frame. Fade that final short arc as it reaches zero.
                        .opacity(min(1, 2 * Double.pi * Double(radius) * progress / Double(max(1, lineWidth))))
                }
            }
            .padding(lineWidth / 2)
            // The arc provides its own round endpoint. Add depth only where the end
            // overlaps the beginning, keeping the shadow on the ring itself.
            if progress > 0.5 && capDistance < lineWidth {
                Circle().fill(palette.start)
                    .frame(width: lineWidth, height: lineWidth)
                    .shadow(color: .black.opacity(0.32 * Double(1 - capDistance / lineWidth)),
                            radius: lineWidth * 0.07,
                            x: -sin(angle) * lineWidth * 0.08, y: cos(angle) * lineWidth * 0.08)
                    .position(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                    .mask {
                        Circle().stroke(style: StrokeStyle(lineWidth: lineWidth))
                            .padding(lineWidth / 2)
                    }
            }
        }
        // This view already interpolates fraction. Do not animate its trim a second time.
        .transaction { $0.animation = nil }
    }
}

/// Rings with today's remainders in the center, then overspending notes and the month line.
struct BudgetRingsCard: View {
    let personal: DailyBudgetSnapshot?
    let family: DailyBudgetSnapshot?
    var isToday = true
    var showsMonth = false
    var togglePeriod: () -> Void = {}
    let reviewPlan: (BudgetScope) -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 40
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            rings
            outlook
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder var rings: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: FolkiSpacing.card) {
                FinancialRings(personal: personal, family: family, showsMonth: showsMonth)
                    .frame(width: 160, height: 160).accessibilityHidden(true)
                Button(action: togglePeriod) {
                    VStack(alignment: .leading, spacing: FolkiSpacing.item) {
                        accessibleAmount(personal, title: String(localized: "Личный"))
                        accessibleAmount(family, title: String(localized: "Семейный"))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityHint("Переключить остатки дня и месяца")
            }
        } else {
            GeometryReader { geometry in
                let diameter = min(geometry.size.width, geometry.size.height)
                ZStack {
                    FinancialRings(personal: personal, family: family, showsMonth: showsMonth)
                        .padding(diameter * 0.06)
                    Button(action: togglePeriod) { center(diameter: diameter) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showsMonth ? String(localized: "Остатки месяца") : String(localized: "Остатки дня"))
                        .accessibilityValue("Личный: \(periodValue(personal)). Семейный: \(periodValue(family)).")
                        .accessibilityHint(showsMonth ? String(localized: "Показать остатки дня") : String(localized: "Показать остатки месяца"))
                        .frame(width: diameter * 0.48, height: diameter * 0.42)
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func periodValue(_ result: DailyBudgetSnapshot?) -> String {
        guard let result else { return String(localized: "не настроен") }
        return MoneyText.whole(showsMonth ? result.monthlyRemaining : result.todayRemaining)
    }

    private func accessibleAmount(_ result: DailyBudgetSnapshot?, title: String) -> some View {
        let money = showsMonth ? result?.monthlyRemaining : result?.todayRemaining
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(title) · \(showsMonth ? "месяц" : "день")").font(.subheadline).foregroundStyle(.secondary)
            Text(money.map(MoneyText.whole) ?? String(localized: "Не настроен"))
                .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.4)
                .foregroundStyle(money.map { $0.minorUnits < 0 } == true ? Color.red : Color.folkiInk)
        }
    }

    var outlook: some View {
        VStack(alignment: .leading, spacing: 6) {
            monthLine
            notes
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func center(diameter: CGFloat) -> some View {
        VStack(spacing: 4) {
            Text(showsMonth ? String(localized: "Личный · месяц") : String(localized: "Личный")).font(.caption.weight(.semibold)).foregroundStyle(Color.budget(.personal))
            amount(showsMonth ? personal?.monthlyRemaining : personal?.todayRemaining, size: min(amountSize, diameter * 0.13), width: diameter * 0.48)
            Text(showsMonth ? String(localized: "Семейный · месяц") : String(localized: "Семейный")).font(.caption2.weight(.semibold)).foregroundStyle(Color.budget(.family)).padding(.top, 4)
            amount(showsMonth ? family?.monthlyRemaining : family?.todayRemaining, size: min(amountSize * 0.65, diameter * 0.085), width: diameter * 0.48)
        }
        .lineLimit(1).minimumScaleFactor(0.3)
    }

    private func amount(_ money: Money?, size: CGFloat, width: CGFloat) -> some View {
        let whole = money?.roundedDownToWholeUnits
        let text = whole.map(MoneyText.whole) ?? "—"
        // Measure the complete amount including minus, grouping spaces and currency.
        // Fit to the clear center of the rings before SwiftUI lays out the label.
        let measured = (text as NSString).size(withAttributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        ]).width
        let fitted = size * min(1, width * 0.95 / max(1, measured))
        return Text(text)
            .font(.system(size: fitted, weight: .bold, design: .rounded)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.1)
            .frame(width: width, height: size * 1.25)
            .foregroundStyle(whole.map { $0.minorUnits < 0 } == true ? Color.red : .primary)
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(whole?.minorUnits ?? 0)))
            .animation(reduceMotion ? nil : .snappy, value: whole?.minorUnits)
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
        let name = scope == .personal ? String(localized: "Личный") : String(localized: "Семейный")
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text("Месяц").foregroundStyle(.secondary)
                monthValue(personal, scope: .personal)
                Text("·").foregroundStyle(.tertiary)
                monthValue(family, scope: .family)
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Личный · месяц").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    monthValue(personal, scope: .personal)
                }
                HStack {
                    Text("Семейный · месяц").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    monthValue(family, scope: .family)
                }
            }
        }.font(.subheadline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
    }

    private func monthValue(_ result: DailyBudgetSnapshot?, scope: BudgetScope) -> some View {
        let value = result?.monthlyRemaining.roundedDownToWholeUnits
        return Text(value.map(MoneyText.whole) ?? String(localized: "не настроен"))
            .fontWeight(.semibold)
            .foregroundStyle(value.map { $0.minorUnits < 0 } == true ? Color.red : Color.budget(scope))
    }

    private func spoken(_ result: DailyBudgetSnapshot?) -> String {
        guard let result else { return String(localized: "не настроен") }
        return String(localized: "сегодня \(MoneyText.whole(result.todayRemaining.roundedDownToWholeUnits)), месяц \(MoneyText.whole(result.monthlyRemaining.roundedDownToWholeUnits))")
    }
}
