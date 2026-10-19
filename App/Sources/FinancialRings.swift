import SwiftUI
import UIKit
import FolkiDuoCore

/// Outside in: personal day, family day, personal month, family month.
struct FinancialRings: View {
    let personal: DailyBudgetSnapshot?
    let family: DailyBudgetSnapshot?
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var fractions: [Double] {
        [personal?.dayRingFraction ?? 0, family?.dayRingFraction ?? 0,
         personal?.monthRingFraction ?? 0, family?.monthRingFraction ?? 0]
    }
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let width = size * (compact ? 0.048 : 0.05)
            let gap = size * 0.012
            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    FinancialRing(fraction: fractions[index], palette: RingPalette.all[index], lineWidth: width)
                        .padding(CGFloat(index) * (width + gap))
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.65), value: fractions)
    }
}

struct RingPalette {
    let start: (Double, Double, Double)
    let end: (Double, Double, Double)
    static let all = [
        RingPalette(start: (1, 0.40, 0.03), end: (1, 0.69, 0.16)),
        RingPalette(start: (0.02, 0.58, 0.57), end: (0.15, 0.85, 0.73)),
        RingPalette(start: (0.43, 0.28, 0.91), end: (0.74, 0.48, 1)),
        RingPalette(start: (0.12, 0.37, 0.88), end: (0.35, 0.67, 1))
    ]
    func color(at fraction: Double) -> Color {
        Color(red: start.0 + (end.0 - start.0) * fraction,
              green: start.1 + (end.1 - start.1) * fraction,
              blue: start.2 + (end.2 - start.2) * fraction)
    }
    func readableColor(in scheme: ColorScheme) -> Color {
        let factor = scheme == .dark ? 1.0 : 0.58
        let fraction = 0.65
        return Color(red: (start.0 + (end.0 - start.0) * fraction) * factor,
                     green: (start.1 + (end.1 - start.1) * fraction) * factor,
                     blue: (start.2 + (end.2 - start.2) * fraction) * factor)
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
            let size = min(geometry.size.width, geometry.size.height)
            let radius = max(0, (size - lineWidth) / 2)
            let angle = progress * 2 * .pi - .pi / 2
            ZStack {
                Circle().stroke(palette.color(at: 0.25).opacity(colorScheme == .dark ? 0.18 : 0.10), lineWidth: lineWidth)
                    .padding(lineWidth / 2)
                if progress > 0 {
                    Circle().trim(from: 0, to: progress)
                        .stroke(AngularGradient(colors: [palette.color(at: 0), palette.color(at: 1)], center: .center),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(lineWidth / 2)
                    if progress < 0.999 {
                        Circle().fill(palette.color(at: 0))
                            .frame(width: lineWidth, height: lineWidth)
                            .position(x: size / 2, y: lineWidth / 2)
                    }
                    Circle().fill(palette.color(at: progress))
                        .frame(width: lineWidth, height: lineWidth)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.12), radius: 2, x: 0, y: 1)
                        .position(x: size / 2 + cos(angle) * radius, y: size / 2 + sin(angle) * radius)
                }
            }
            .frame(width: size, height: size)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

struct BudgetRingsCard: View {
    let personal: DailyBudgetSnapshot?
    let family: DailyBudgetSnapshot?
    var isToday = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 34
    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                ZStack {
                    FinancialRings(personal: personal, family: family)
                    ViewThatFits(in: .vertical) {
                        centralAmounts(large: true, width: size * 0.50)
                        centralAmounts(large: false, width: size * 0.50)
                    }.frame(width: size * 0.50, height: size * 0.48)
                }
            }.aspectRatio(1, contentMode: .fit).frame(maxWidth: 304)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 18) {
                metric("Личный · день", index: 0, remaining: personal?.todayRemaining, plan: personal?.todayGuide)
                metric("Семейный · день", index: 1, remaining: family?.todayRemaining, plan: family?.todayGuide)
                metric("Личный · месяц", index: 2, remaining: personal?.monthlyRemaining, plan: personal?.monthlyPlan)
                metric("Семейный · месяц", index: 3, remaining: family?.monthlyRemaining, plan: family?.monthlyPlan)
            }.padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isToday ? "Сегодня" : "Выбранный день"). Личный бюджет: \(description(personal)). Семейный бюджет: \(description(family)).")
        .accessibilityHint("Открыть расчёт выбранного бюджета")
    }
    private func centralAmounts(large: Bool, width: CGFloat) -> some View {
        let personalText = personal.map { MoneyText.string($0.todayRemaining.minorUnits >= 0 ? $0.todayRemaining : $0.todayOverspending) } ?? "—"
        let desiredSize = amountSize * (large ? 1 : 0.85)
        let measured = (personalText as NSString).size(withAttributes: [.font: roundedFont(size: desiredSize, weight: .bold)]).width
        let fittedSize = min(desiredSize, desiredSize * width / max(1, measured))
        return VStack(spacing: large ? 5 : 2) {
            Text(personal.map { $0.todayRemaining.minorUnits < 0 ? "Личный · сверх плана" : "Личный · \(isToday ? "сегодня" : "день")" } ?? "Личный")
                .font(large ? .caption : .caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
            Text(personalText)
                .font(Font(roundedFont(size: fittedSize, weight: .bold)))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            Text(family.map { $0.todayRemaining.minorUnits < 0 ? "Общий · сверх плана" : "Общий · \(isToday ? "сегодня" : "день")" } ?? "Общий")
                .font(.caption2).foregroundStyle(.secondary).padding(.top, large ? 3 : 0).lineLimit(1).minimumScaleFactor(0.6)
            Text(family.map { MoneyText.string($0.todayRemaining.minorUnits >= 0 ? $0.todayRemaining : $0.todayOverspending) } ?? "—")
                .font(Font(roundedFont(size: fittedSize * 0.64, weight: .semibold)))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
        }
    }
    private func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return UIFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: size)
    }
    private func metric(_ title: String, index: Int, remaining: Money?, plan: Money?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(remaining.map(MoneyText.string) ?? "—").font(.title3.bold()).monospacedDigit()
                .foregroundStyle(RingPalette.all[index].readableColor(in: colorScheme))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(plan.map { "из \(MoneyText.string($0))" } ?? "Не настроен")
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func description(_ result: DailyBudgetSnapshot?) -> String {
        guard let result else { return "не настроен" }
        return "\(isToday ? "сегодня" : "день") \(MoneyText.string(result.todayRemaining)) из \(MoneyText.string(result.todayGuide)), месяц \(MoneyText.string(result.monthlyRemaining)) из \(MoneyText.string(result.monthlyPlan))"
    }
}
