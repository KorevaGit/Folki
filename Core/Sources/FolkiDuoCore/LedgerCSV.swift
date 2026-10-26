import Foundation

/// A ledger as a spreadsheet: semicolons and decimal commas, as Russian Excel and Numbers expect.
public enum LedgerCSV {
    public struct Row: Sendable {
        public let date: Date
        public let budget: String
        public let kind: String
        public let category: String
        /// Signed: money out of the budget is negative.
        public let amount: Money
        public let author: String
        public let title: String
        public init(date: Date, budget: String, kind: String, category: String, amount: Money, author: String, title: String) {
            self.date = date; self.budget = budget; self.kind = kind; self.category = category
            self.amount = amount; self.author = author; self.title = title
        }
    }

    /// The byte-order mark lets Excel read Cyrillic as UTF-8; rows go oldest first.
    public static func make(header: [String], rows: [Row], timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let lines = rows.sorted { $0.date < $1.date }.map { row in
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: row.date)
            let date = String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                              parts.hour ?? 0, parts.minute ?? 0)
            return [date, row.budget, row.kind, row.category, amountText(row.amount), row.author, row.title]
                .map(field).joined(separator: ";")
        }
        return "\u{FEFF}" + ([header.map(field).joined(separator: ";")] + lines).joined(separator: "\r\n") + "\r\n"
    }

    /// "-1234,50": no grouping, so spreadsheets read it as a number.
    static func amountText(_ money: Money) -> String {
        let scale = money.currency.scale
        let magnitude = money.minorUnits.magnitude
        let whole = magnitude / UInt64(scale)
        let sign = money.minorUnits < 0 ? "-" : ""
        guard money.currency.fractionDigits > 0 else { return sign + String(whole) }
        let fraction = String(magnitude % UInt64(scale))
        return sign + String(whole) + "," + String(repeating: "0", count: money.currency.fractionDigits - fraction.count) + fraction
    }

    /// Quotes a field that holds a separator, a quote or a line break; a leading formula sign is defused.
    static func field(_ value: String) -> String {
        var text = value
        if let first = text.first, "=+-@".contains(first), Double(text.replacingOccurrences(of: ",", with: ".")) == nil {
            text = "'" + text
        }
        guard text.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
