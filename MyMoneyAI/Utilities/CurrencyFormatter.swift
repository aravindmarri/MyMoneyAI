import Foundation

/// Money helpers. Stored amounts are Int64 minor units; Decimal is used for any conversion.
/// Binary floating point is never used for money.
enum CurrencyMath {
    static let defaultCode = "USD"
    static let supportedCodes = ["USD", "EUR", "GBP", "CAD", "AUD", "INR", "JPY"]

    /// ISO 4217 minor-unit exponents that differ from 2.
    private static let exponents: [String: Int] = [
        "JPY": 0, "KRW": 0, "VND": 0, "CLP": 0, "ISK": 0, "UGX": 0,
        "BHD": 3, "KWD": 3, "OMR": 3, "JOD": 3, "TND": 3, "LYD": 3, "IQD": 3,
    ]

    static func exponent(for code: String) -> Int { exponents[code.uppercased()] ?? 2 }

    static func decimal(fromMinorUnits minor: Int64, currencyCode: String) -> Decimal {
        Decimal(minor) / pow(Decimal(10), exponent(for: currencyCode))
    }

    /// Converts a decimal amount to minor units, rounding half away from zero.
    /// Returns nil if the value does not fit in Int64.
    static func minorUnits(from value: Decimal, currencyCode: String) -> Int64? {
        var scaled = value * pow(Decimal(10), exponent(for: currencyCode))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let n = NSDecimalNumber(decimal: rounded)
        guard n.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending,
              n.compare(NSDecimalNumber(value: Int64.min)) != .orderedAscending else { return nil }
        return n.int64Value
    }

    static func format(_ minor: Int64, currencyCode: String, locale: Locale = .current) -> String {
        decimal(fromMinorUnits: minor, currencyCode: currencyCode)
            .formatted(.currency(code: currencyCode).locale(locale))
    }
}
