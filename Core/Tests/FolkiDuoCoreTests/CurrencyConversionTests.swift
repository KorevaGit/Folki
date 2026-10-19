import Foundation
import Testing
@testable import FolkiDuoCore

struct CurrencyConversionTests {
    private let date = Date(timeIntervalSince1970: 1_792_180_800)
    @Test func convertsBothDirectionsWithoutChangingOriginalAmount() throws {
        let quote = try CurrencyQuote(code: "USD", rublesPerUnit: 100, date: date)
        let original = Money(minorUnits: 1_234_567)
        #expect(try quote.fromRubles(original).minorUnits == 12_346)
        #expect(try quote.toRubles(Money(parsing: "12.34", currency: quote.currency)).minorUnits == 123_400)
        let displayed = try quote.fromRubles(original)
        #expect(try quote.toRubles(displayed, preserving: original) == original)
        let commaInput = try Money(parsing: "123,46", currency: quote.currency)
        #expect(try quote.toRubles(commaInput, preserving: original) == original)
        #expect(original.minorUnits == 1_234_567)
    }
    @Test func roundsSignedMinorUnitsAndZeroDigitCurrency() throws {
        let dollar = try CurrencyQuote(code: "USD", rublesPerUnit: 2, date: date)
        #expect(try dollar.fromRubles(Money(minorUnits: 1)).minorUnits == 1)
        #expect(try dollar.fromRubles(Money(minorUnits: -1)).minorUnits == -1)
        let yen = try CurrencyQuote(code: "JPY", rublesPerUnit: Decimal(string: "0.5")!, date: date)
        #expect(try yen.fromRubles(Money(minorUnits: 125)).minorUnits == 3)
        #expect(yen.currency.fractionDigits == 0)
    }
    @Test func rejectsInvalidRatesOverflowAndMismatchedCurrency() throws {
        #expect(throws: ExchangeRateError.invalidRate) { try CurrencyQuote(code: "USD", rublesPerUnit: 0, date: date) }
        let quote = try CurrencyQuote(code: "USD", rublesPerUnit: 100, date: date)
        #expect(throws: BudgetError.amountOverflow) {
            try quote.toRubles(Money(minorUnits: .max, currency: quote.currency))
        }
        #expect(throws: BudgetError.currencyMismatch) { try quote.toRubles(Money(minorUnits: 100)) }
    }
    @Test func parsesNominalAndQuoteDateAndPersistsExactly() throws {
        let xml = """
        <ValCurs Date="17.10.2026"><Valute><CharCode>JPY</CharCode><Nominal>100</Nominal><Value>52,1234</Value></Valute></ValCurs>
        """
        let rates = try ExchangeRates.parseCBR(Data(xml.utf8))
        #expect(rates.rublesPerUnit["JPY"] == Decimal(string: "0.521234"))
        #expect(rates.rublesPerUnit["RUB"] == 1)
        let quote = try rates.quote(for: "JPY")
        let restored = try JSONDecoder().decode(CurrencyQuote.self, from: JSONEncoder().encode(quote))
        #expect(restored == quote)
        let invalidCache = Data(#"{"code":"usd","rublesPerUnit":100,"date":0,"isManual":false}"#.utf8)
        #expect(throws: BudgetError.invalidCurrency) { try JSONDecoder().decode(CurrencyQuote.self, from: invalidCache) }
        #expect(throws: ExchangeRateError.missingCurrency) { try rates.quote(for: "USD") }
    }
    @Test(arguments: ["<html>Unavailable</html>", "<ValCurs Date=\"bad\"/>",
        "<ValCurs Date=\"17.10.2026\"><Valute><CharCode>USD</CharCode><Nominal>0</Nominal><Value>1,00</Value></Valute></ValCurs>"])
    func rejectsIncompleteOrInvalidFeed(_ xml: String) {
        #expect(throws: ExchangeRateError.invalidFeed) { try ExchangeRates.parseCBR(Data(xml.utf8)) }
    }
}
