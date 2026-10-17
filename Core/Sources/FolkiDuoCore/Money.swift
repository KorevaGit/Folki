import Foundation

public enum BudgetError: Error, Equatable, Sendable {
    case invalidCurrency, invalidAmount, amountOverflow, currencyMismatch
    case invalidPeriod, invalidTimeZone, dateOutsidePeriod, invalidDayCount
    case invalidPlan, duplicateIdentifier, missingReserve, insufficientReserve
    case invalidTransaction
}

public struct Currency: Hashable, Sendable {
    public let code: String
    public let fractionDigits: Int
    public static let rub = Currency(validatedCode: "RUB", fractionDigits: 2)

    public init(code: String, fractionDigits: Int) throws {
        guard code.utf8.count == 3, code.utf8.allSatisfy({ (65...90).contains($0) }),
              (0...4).contains(fractionDigits) else { throw BudgetError.invalidCurrency }
        self.init(validatedCode: code, fractionDigits: fractionDigits)
    }

    private init(validatedCode: String, fractionDigits: Int) {
        code = validatedCode
        self.fractionDigits = fractionDigits
    }

    public var scale: Int64 { (0..<fractionDigits).reduce(1) { value, _ in value * 10 } }
}

/// Signed money in integer minor units. All financial arithmetic is checked.
public struct Money: Hashable, Sendable {
    public let minorUnits: Int64
    public let currency: Currency

    public init(minorUnits: Int64, currency: Currency = .rub) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    public var decimalValue: Decimal { Decimal(minorUnits) / Decimal(currency.scale) }

    /// Full-string validation: no partial Decimal parsing or silent fractional rounding.
    public init(parsing input: String, currency: Currency = .rub) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let fractional = currency.fractionDigits > 0 ? "(?:[.,][0-9]{1,\(currency.fractionDigits)})?" : ""
        let pattern = "^[+-]?(?:[0-9]+|[0-9]{1,3}(?:[ \u{00a0}\u{202f}][0-9]{3})+)\(fractional)$"
        guard !value.isEmpty, value.count <= 80,
              value.range(of: pattern, options: .regularExpression) != nil else {
            throw BudgetError.invalidAmount
        }
        let normalized = value.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: "\u{202f}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else {
            throw BudgetError.invalidAmount
        }
        let scaled = decimal * Decimal(currency.scale)
        guard !scaled.isNaN, scaled >= Decimal(Int64.min), scaled <= Decimal(Int64.max) else {
            throw BudgetError.amountOverflow
        }
        let integer = NSDecimalNumber(decimal: scaled).int64Value
        guard Decimal(integer) == scaled else { throw BudgetError.invalidAmount }
        self.init(minorUnits: integer, currency: currency)
    }

    public func adding(_ other: Money) throws -> Money {
        guard currency == other.currency else { throw BudgetError.currencyMismatch }
        let result = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !result.overflow else { throw BudgetError.amountOverflow }
        return Money(minorUnits: result.partialValue, currency: currency)
    }

    public func subtracting(_ other: Money) throws -> Money {
        guard currency == other.currency else { throw BudgetError.currencyMismatch }
        let result = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !result.overflow else { throw BudgetError.amountOverflow }
        return Money(minorUnits: result.partialValue, currency: currency)
    }

    public var nonnegative: Money { Money(minorUnits: max(0, minorUnits), currency: currency) }
}

/// Exact distribution: the first extraUnitDays receive one additional minor unit.
public struct DailyAllocation: Equatable, Sendable {
    public let total: Money
    public let days: Int
    public let standardAmount: Money
    public let extraUnitDays: Int

    public init(total: Money, days: Int) throws {
        guard days > 0 else { throw BudgetError.invalidDayCount }
        guard total.minorUnits >= 0 else { throw BudgetError.invalidAmount }
        self.total = total
        self.days = days
        standardAmount = Money(minorUnits: total.minorUnits / Int64(days), currency: total.currency)
        extraUnitDays = Int(total.minorUnits % Int64(days))
    }

    public func amount(forDay index: Int) throws -> Money {
        guard (0..<days).contains(index) else { throw BudgetError.invalidDayCount }
        return try standardAmount.adding(Money(minorUnits: index < extraUnitDays ? 1 : 0, currency: total.currency))
    }

    public var firstDayAmount: Money {
        Money(minorUnits: standardAmount.minorUnits + (extraUnitDays > 0 ? 1 : 0), currency: total.currency)
    }
}
