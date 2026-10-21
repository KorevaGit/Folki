import Foundation

/// What the widgets show, written by the app into the shared App Group after every change.
/// Amounts are kopecks; the widget never opens the store.
struct FolkiWidgetSnapshot: Codable, Equatable {
    struct Budget: Codable, Equatable {
        /// Left of today's guide; negative when over.
        var today: Int64
        var guide: Int64
        /// Tomorrow's daily figure, nil on the period's last day.
        var tomorrow: Int64?
        var periodEnd: Date
    }
    struct Day: Codable, Equatable {
        var date: Date
        var remaining: Int64
        var guide: Int64
        var fraction: Double { guide > 0 ? max(0, min(1, Double(remaining) / Double(guide))) : 0 }
    }
    var familyDays: [Day]? = nil
    /// Recent personal day balances for the weekly widget.
    var days: [Day]? = nil
    /// The envelope that most needs money, for the wide widget.
    struct Envelope: Codable, Equatable {
        var id: UUID
        var name: String
        var symbol: String
        /// Icon colour as sRGB components.
        var red: Double, green: Double, blue: Double
        var size: Int64
        var saved: Int64
        var due: Date
    }
    /// Start of the day the figures are for.
    var day: Date
    var personal: Budget?
    var family: Budget?
    var envelope: Envelope?
    var updated: Date

    static let appGroup = "group.dev.korevagit.folki"
    private static let key = "FolkiWidgetSnapshot"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> FolkiWidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FolkiWidgetSnapshot.self, from: data)
    }
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults?.set(data, forKey: Self.key)
    }

    /// The figures for `date`: after midnight today's guide is tomorrow's figure, untouched.
    func budget(_ budget: Budget?, on date: Date, calendar: Calendar = .current) -> Budget? {
        guard let budget else { return nil }
        guard !calendar.isDate(date, inSameDayAs: day) else { return budget }
        guard date < budget.periodEnd, let next = budget.tomorrow else { return nil }
        return Budget(today: next, guide: next, tomorrow: nil, periodEnd: budget.periodEnd)
    }
}

extension FolkiWidgetSnapshot.Budget {
    var fraction: Double { guide > 0 ? max(0, min(1, Double(today) / Double(guide))) : 0 }
    var isOver: Bool { today < 0 }
}

enum FolkiWidgetText {
    /// Whole roubles with grouping: 1 211 ₽, −320 ₽.
    static func rub(_ kopecks: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{2009}"
        formatter.maximumFractionDigits = 0
        let whole = kopecks >= 0 ? kopecks / 100 : -((-kopecks + 99) / 100)
        let digits = formatter.string(from: NSNumber(value: abs(whole))) ?? "\(abs(whole))"
        return (whole < 0 ? "−" : "") + digits + "\u{00A0}₽"
    }
}

extension FolkiWidgetSnapshot.Envelope {
    var missing: Int64 { max(0, size - saved) }
    var fraction: Double { size > 0 ? max(0, min(1, Double(saved) / Double(size))) : 0 }
    /// Whole days from `date` to the payment; negative when overdue.
    func daysLeft(from date: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: due)).day ?? 0
    }
}

/// The deep links the widgets and intents use.
enum FolkiLinks {
    static let spend = URL(string: "folki://spend")!
    static let add = URL(string: "folki://add")!
    static func envelope(_ id: UUID) -> URL { URL(string: "folki://envelope/\(id.uuidString)")! }
}
