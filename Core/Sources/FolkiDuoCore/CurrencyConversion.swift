import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum ExchangeRateError: Error, Equatable, Sendable {
    case invalidRate, invalidFeed, missingCurrency
}

/// A quote is RUB per one unit of the selected currency, never per nominal lot.
public struct CurrencyQuote: Codable, Equatable, Sendable {
    public let code: String
    public let rublesPerUnit: Decimal
    public let date: Date
    public let isManual: Bool
    public var currency: Currency { try! Currency(code: code, fractionDigits: code == "JPY" ? 0 : 2) }

    public init(code: String, rublesPerUnit: Decimal, date: Date, isManual: Bool = false) throws {
        _ = try Currency(code: code, fractionDigits: 2)
        guard !rublesPerUnit.isNaN, rublesPerUnit > 0 else { throw ExchangeRateError.invalidRate }
        self.code = code; self.rublesPerUnit = rublesPerUnit; self.date = date; self.isManual = isManual
    }
    private enum CodingKeys: String, CodingKey { case code, rublesPerUnit, date, isManual }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(code: values.decode(String.self, forKey: .code),
                      rublesPerUnit: values.decode(Decimal.self, forKey: .rublesPerUnit),
                      date: values.decode(Date.self, forKey: .date), isManual: values.decode(Bool.self, forKey: .isManual))
    }

    public func fromRubles(_ money: Money) throws -> Money {
        guard money.currency == .rub else { throw BudgetError.currencyMismatch }
        return try convert(money.decimalValue / rublesPerUnit, to: currency)
    }
    public func toRubles(_ money: Money, preserving original: Money? = nil) throws -> Money {
        guard money.currency == currency else { throw BudgetError.currencyMismatch }
        if let original, try fromRubles(original) == money { return original }
        return try convert(money.decimalValue * rublesPerUnit, to: .rub)
    }
    private func convert(_ amount: Decimal, to currency: Currency) throws -> Money {
        var scaled = amount * Decimal(currency.scale)
        guard !scaled.isNaN else { throw BudgetError.amountOverflow }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded >= Decimal(Int64.min), rounded <= Decimal(Int64.max) else { throw BudgetError.amountOverflow }
        return Money(minorUnits: NSDecimalNumber(decimal: rounded).int64Value, currency: currency)
    }
}

public struct ExchangeRates: Codable, Sendable {
    public let date: Date
    public let rublesPerUnit: [String: Decimal]

    public func quote(for code: String) throws -> CurrencyQuote {
        guard let rate = rublesPerUnit[code] else { throw ExchangeRateError.missingCurrency }
        return try CurrencyQuote(code: code, rublesPerUnit: rate, date: date)
    }
    public static func parseCBR(_ data: Data) throws -> ExchangeRates {
        let reader = CBRRateReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid, let date = reader.date, !reader.rates.isEmpty else {
            throw ExchangeRateError.invalidFeed
        }
        return ExchangeRates(date: date, rublesPerUnit: reader.rates.merging(["RUB": 1]) { first, _ in first })
    }
}

private final class CBRRateReader: NSObject, XMLParserDelegate {
    var date: Date?
    var rates: [String: Decimal] = [:]
    var invalid = false
    private var value = ""
    private var fields: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        value = ""
        if elementName == "ValCurs" {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "Europe/Moscow")
            formatter.dateFormat = "dd.MM.yyyy"
            formatter.isLenient = false
            date = attributeDict["Date"].flatMap(formatter.date(from:))
        }
        if elementName == "Valute" { fields = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if ["CharCode", "Nominal", "Value"].contains(elementName) { fields[elementName] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard elementName == "Valute" else { return }
        guard let code = fields["CharCode"], (try? Currency(code: code, fractionDigits: 2)) != nil,
              let nominalText = fields["Nominal"], let nominal = Int(nominalText), nominal > 0,
              let text = fields["Value"], text.range(of: "^[0-9]+(?:,[0-9]+)?$", options: .regularExpression) != nil,
              let amount = Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")),
              amount > 0, rates[code] == nil else { invalid = true; return }
        rates[code] = amount / Decimal(nominal)
    }
}
