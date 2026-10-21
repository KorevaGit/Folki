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
    /// Start of the day the figures are for.
    var day: Date
    var personal: Budget?
    var family: Budget?
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

/// The deep link the widgets and intents use to open the spend sheet.
enum FolkiLinks {
    static let spend = URL(string: "folki://spend")!
    static let add = URL(string: "folki://add")!
}
