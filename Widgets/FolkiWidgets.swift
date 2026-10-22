import SwiftUI
import WidgetKit
import AppIntents

@main
struct FolkiWidgetBundle: WidgetBundle {
    var body: some Widget {
        FolkiBudgetWidget()
        FolkiSpendControl()
    }
}

// MARK: - Timeline

struct FolkiEntry: TimelineEntry {
    let date: Date
    let personal: FolkiWidgetSnapshot.Budget?
    let family: FolkiWidgetSnapshot.Budget?
    var envelope: FolkiWidgetSnapshot.Envelope? = nil
    var days: [FolkiWidgetSnapshot.Day] = []
    var familyDays: [FolkiWidgetSnapshot.Day] = []
    /// The app has never written a snapshot: ask to open it.
    let empty: Bool

    static let preview = FolkiEntry(date: .now,
        personal: .init(today: 121_100, guide: 200_000, tomorrow: 198_000, periodEnd: .now.addingTimeInterval(20 * 86_400)),
        family: .init(today: 80_000, guide: 150_000, tomorrow: 140_000, periodEnd: .now.addingTimeInterval(20 * 86_400)),
        envelope: .init(id: UUID(), name: String(localized: "Аренда"), symbol: "house.fill", red: 0.61, green: 0.42, blue: 0.25,
                        size: 2_500_000, saved: 1_300_000, due: .now.addingTimeInterval(4 * 86_400)),
        empty: false)
}

struct FolkiProvider: TimelineProvider {
    func placeholder(in context: Context) -> FolkiEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (FolkiEntry) -> Void) {
        completion(context.isPreview ? .preview : entries().first ?? .preview)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FolkiEntry>) -> Void) {
        // Now, and a fresh day at midnight; the app reloads the timeline on every change.
        completion(Timeline(entries: entries(), policy: .atEnd))
    }

    private func entries() -> [FolkiEntry] {
        let now = Date.now
        guard let snapshot = FolkiWidgetSnapshot.load() else {
            return [FolkiEntry(date: now, personal: nil, family: nil, empty: true)]
        }
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now.addingTimeInterval(86_400))
        return [now, midnight].map { date in
            FolkiEntry(date: date, personal: snapshot.budget(snapshot.personal, on: date),
                       family: snapshot.budget(snapshot.family, on: date), envelope: snapshot.envelope, days: snapshot.days ?? [], familyDays: snapshot.familyDays ?? [], empty: false)
        }
    }
}

// MARK: - Widget

struct FolkiBudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FolkiBudget", provider: FolkiProvider()) { entry in
            FolkiWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(FolkiLinks.spend)
        }
        .configurationDisplayName("Сегодня можно")
        .description("Сколько ещё можно потратить сегодня")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private enum Palette {
    static let personal = Color(red: 0.937, green: 0.624, blue: 0.153) // #EF9F27
    static let family = Color(red: 0.831, green: 0.325, blue: 0.494)
    static let accent = Color(red: 0.06, green: 0.43, blue: 0.34)
    static let amber = Color(red: 0.85, green: 0.60, blue: 0.12)
}

struct FolkiWidgetView: View {
    let entry: FolkiEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if entry.empty || entry.personal == nil {
            emptyView
        } else {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .systemMedium: medium
            default: small
            }
        }
    }

    private var personal: FolkiWidgetSnapshot.Budget { entry.personal! }

    private func caption(_ budget: FolkiWidgetSnapshot.Budget) -> LocalizedStringKey {
        budget.isOver ? "Сверх дня" : "Сегодня можно"
    }

    // Home screen

    /// As on the main screen: the rings fill the widget, today's figure sits in the middle.
    private var small: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                rings(size: side, width: side * 0.09)
                VStack(spacing: 1) {
                    Text(personal.isOver ? "Сверх дня" : "Сегодня")
                        .font(.system(size: side * 0.075, weight: .semibold))
                        .foregroundStyle(personal.isOver ? Color.red : Palette.personal)
                    Text(FolkiWidgetText.rub(personal.today))
                        .font(.system(size: side * 0.15, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(personal.isOver ? Color.red : .primary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    if let family = entry.family {
                        Text("≈ \(FolkiWidgetText.rub(family.today))")
                            .font(.system(size: side * 0.07, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Palette.family).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                .frame(width: side * (entry.family == nil ? 0.62 : 0.5))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The wide widget mirrors the compact weekly summary.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(caption(personal)).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(personal.isOver ? Color.red : weekAmber)
                    Text(FolkiWidgetText.rub(personal.today))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                        .foregroundStyle(personal.isOver ? Color.red : .primary)
                    if let family = entry.family {
                        Text("Семья ≈ \(FolkiWidgetText.rub(family.today))")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(familyInk)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                Spacer(minLength: 0)
                Link(destination: FolkiLinks.spend) {
                    Text("− Потратить").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(red: 0.02, green: 0.16, blue: 0.12))
                        .padding(.horizontal, 15).frame(height: 33)
                        .background(weekAccent, in: Capsule())
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                ForEach(weekDates, id: \.self) { date in
                    weekDay(date).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var familyTint: Color {
        scheme == .dark ? Color(red: 0.929, green: 0.576, blue: 0.694) : Palette.family
    }
    private var familyInk: Color {
        scheme == .dark ? Color(red: 0.957, green: 0.753, blue: 0.820) : Color(red: 0.600, green: 0.208, blue: 0.337)
    }
    private var weekAmber: Color { scheme == .dark ? Color(red: 1, green: 0.71, blue: 0.27) : Palette.personal }
    private var weekAccent: Color { Color(red: 0.11, green: 0.62, blue: 0.46) }

    private var weekDates: [Date] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let start = calendar.dateInterval(of: .weekOfYear, for: entry.date)?.start ?? calendar.startOfDay(for: entry.date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func weekDay(_ date: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDate(date, inSameDayAs: entry.date)
        let isFuture = calendar.startOfDay(for: date) > calendar.startOfDay(for: entry.date)
        let balance = entry.days.first { calendar.isDate($0.date, inSameDayAs: date) }
        let familyBalance = entry.familyDays.first { calendar.isDate($0.date, inSameDayAs: date) }
        let familyFraction = isToday ? entry.family?.fraction : familyBalance?.fraction
        let fraction = isToday ? personal.fraction : balance?.fraction ?? 0
        let isOver = isToday ? personal.isOver : (balance?.remaining ?? 0) < 0
        let weekday = date.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).weekday(.abbreviated))
        return VStack(spacing: 4) {
            Text(weekday.lowercased().replacingOccurrences(of: ".", with: ""))
                .font(.system(size: 10, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? weekAccent : .secondary)
            ZStack {
                weekRing(fraction, color: weekAmber, width: 3.5, future: isFuture)
                if entry.family != nil {
                    weekRing(familyFraction ?? 0, color: familyTint, width: 2.5, future: isFuture).padding(5.5)
                }
            }
            .frame(width: 28, height: 28)
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 10, weight: .bold)).monospacedDigit()
                .foregroundStyle(isToday ? weekAccent : isOver ? Color.red : .primary)
        }
        .opacity(isFuture ? 0.25 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(date.formatted(.dateTime.day().month().weekday(.wide)))
        .accessibilityValue(isFuture ? String(localized: "Будущий день") :
            String(localized: "Личное: \(Int(fraction * 100)) процентов. Семья: \(Int((familyFraction ?? 0) * 100)) процентов."))
    }

    private func weekRing(_ fraction: Double, color: Color, width: CGFloat, future: Bool) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: width)
            if !future {
                Circle().trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round)).rotationEffect(.degrees(-90))
            }
        }.padding(width / 2)
    }

    private func rings(size: CGFloat, width: CGFloat) -> some View {
        ZStack {
            ring(personal, color: Palette.personal, width: width)
            if let family = entry.family {
                ring(family, color: Palette.family, width: width).padding(width + width * 0.2)
            }
        }
        .frame(width: size, height: size)
    }

    private func ring(_ budget: FolkiWidgetSnapshot.Budget, color: Color, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(budget.isOver ? Color.secondary.opacity(0.15) : color.opacity(0.2), lineWidth: width)
            Circle().trim(from: 0, to: budget.fraction)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .padding(width / 2)
    }

    // Lock screen

    private var circular: some View {
        ZStack {
            lockRing(personal, width: 3.5)
            if let family = entry.family {
                lockRing(family, width: 3).padding(6)
            }
            VStack(spacing: 0) {
                Text(shortAmount(personal.today))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                Text("личное").font(.system(size: 8, weight: .medium))
            }
            .frame(maxWidth: 38)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetAccentable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Личное и семья")
        .accessibilityValue(Text(entry.family.map {
            String(localized: "Личное: \(FolkiWidgetText.rub(personal.today)). Семья: \(FolkiWidgetText.rub($0.today)).")
        } ?? String(localized: "Личное: \(FolkiWidgetText.rub(personal.today)). Семейный бюджет не задан.")))
    }

    private func lockRing(_ budget: FolkiWidgetSnapshot.Budget, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.22), lineWidth: width)
            Circle().trim(from: 0, to: budget.fraction)
                .stroke(.primary, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(width / 2)
    }

    private var rectangular: some View {
        HStack(spacing: 12) {
            lockBudget("Личное", budget: personal)
            lockBudget("Семья", budget: entry.family)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetAccentable()
    }

    private func lockBudget(_ label: LocalizedStringKey, budget: FolkiWidgetSnapshot.Budget?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
            Text(budget.map { FolkiWidgetText.rub($0.today) } ?? "—")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.22))
                    Capsule().fill(.primary)
                        .frame(width: geometry.size.width * (budget?.fraction ?? 0))
                }
            }
            .frame(height: 3).padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(budget.map {
            $0.isOver ? String(localized: "Сверх дня: \(FolkiWidgetText.rub($0.today))")
                : String(localized: "Сегодня можно: \(FolkiWidgetText.rub($0.today))")
        } ?? String(localized: "Бюджет не задан")))
    }

    private var inline: some View {
        Text(personal.isOver ? "Folki: \(FolkiWidgetText.rub(personal.today)) сверх дня"
             : "Folki: \(FolkiWidgetText.rub(personal.today)) сегодня")
    }

    /// 1,2к for the small circular slot.
    private func shortAmount(_ kopecks: Int64) -> String {
        let rub = Double(kopecks) / 100
        if abs(rub) >= 10_000 { return String(format: "%.0fк", rub / 1000) }
        if abs(rub) >= 1_000 { return String(format: "%.1fк", rub / 1000) }
        return String(format: "%.0f", rub)
    }

    @ViewBuilder private var emptyView: some View {
        switch family {
        case .accessoryInline: Text("Открой Folki")
        case .accessoryCircular: Image(systemName: "wallet.bifold")
        default:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "wallet.bifold").font(.title2).foregroundStyle(Palette.accent)
                Spacer(minLength: 0)
                Text("Открой Folki, чтобы задать бюджет").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Control Center / Action Button

struct FolkiSpendControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "FolkiSpend") {
            ControlWidgetButton(action: SpendIntent()) {
                Label("Записать трату", systemImage: "minus.circle.fill")
            }
        }
        .displayName("Записать трату")
        .description("Открывает Folki на вводе траты")
    }
}

#Preview(as: .systemMedium) { FolkiBudgetWidget() } timeline: { FolkiEntry.preview }
#Preview(as: .systemSmall) { FolkiBudgetWidget() } timeline: { FolkiEntry.preview }

#Preview(as: .accessoryRectangular) { FolkiBudgetWidget() } timeline: { FolkiEntry.preview }
