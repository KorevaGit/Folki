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
    /// The app has never written a snapshot: ask to open it.
    let empty: Bool

    static let preview = FolkiEntry(date: .now,
        personal: .init(today: 121_100, guide: 200_000, tomorrow: 198_000, periodEnd: .now.addingTimeInterval(20 * 86_400)),
        family: .init(today: 80_000, guide: 150_000, tomorrow: 140_000, periodEnd: .now.addingTimeInterval(20 * 86_400)),
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
                       family: snapshot.budget(snapshot.family, on: date), empty: false)
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
    static let personal = Color(red: 0.91, green: 0.54, blue: 0.10)
    static let family = Color(red: 0.831, green: 0.325, blue: 0.494)
    static let accent = Color(red: 0.06, green: 0.43, blue: 0.34)
}

struct FolkiWidgetView: View {
    let entry: FolkiEntry
    @Environment(\.widgetFamily) private var family

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

    /// Rings on the left, the figures and the spend button on the right, one leading edge.
    private var medium: some View {
        GeometryReader { geo in
            HStack(spacing: 16) {
                rings(size: geo.size.height, width: geo.size.height * 0.09)
                VStack(alignment: .leading, spacing: 0) {
                    Text(caption(personal)).font(.caption.weight(.semibold))
                        .foregroundStyle(personal.isOver ? Color.red : Palette.personal)
                    Text(FolkiWidgetText.rub(personal.today)).font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                        .foregroundStyle(personal.isOver ? Color.red : .primary)
                    if let family = entry.family {
                        HStack(spacing: 4) {
                            Circle().fill(Palette.family).frame(width: 6, height: 6)
                            Text("Семья ≈ \(FolkiWidgetText.rub(family.today))").font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }.padding(.top, 2)
                    }
                    Spacer(minLength: 6)
                    Link(destination: FolkiLinks.spend) {
                        Text("− Потратить").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Palette.accent, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
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
        Gauge(value: personal.fraction) {
            Text("₽")
        } currentValueLabel: {
            Text(shortAmount(personal.today)).minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption(personal)).font(.caption2.weight(.semibold)).widgetAccentable()
            Text(FolkiWidgetText.rub(personal.today)).font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
            if let family = entry.family {
                Text("Семья ≈ \(FolkiWidgetText.rub(family.today))").font(.caption2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
