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

    /// Parses user-typed amounts such as "12.50", "1,234.56", "1.234,56" or "12,5".
    /// Returns nil for empty input, negative signs, non-numeric text, or more fraction
    /// digits than the currency allows (e.g. "1.234" for USD is read as grouping → 1234.00).
    static func parse(_ text: String, currencyCode: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("-") else { return nil }
        let s = trimmed.filter { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," }
        guard s.contains(where: { $0.isNumber }) else { return nil }
        let exp = exponent(for: currencyCode)

        var decimalSeparator: Character?
        let lastDot = s.lastIndex(of: "."), lastComma = s.lastIndex(of: ",")
        if let d = lastDot, let c = lastComma {
            decimalSeparator = d > c ? "." : ","
        } else if let sep = lastDot ?? lastComma {
            let sepChar = s[sep]
            let occurrences = s.filter { $0 == sepChar }.count
            let fractionDigits = s.distance(from: s.index(after: sep), to: s.endIndex)
            if occurrences == 1 && (fractionDigits != 3 || exp == 3) { decimalSeparator = sepChar }
        }

        // Keep digits; convert only the final decimal separator to "."; drop grouping separators.
        var normalized = ""
        let decimalIndex = decimalSeparator.flatMap { s.lastIndex(of: $0) }
        for i in s.indices {
            if i == decimalIndex { normalized.append(".") }
            else if s[i].isNumber { normalized.append(s[i]) }
        }
        if let dot = normalized.firstIndex(of: ".") {
            let frac = normalized.distance(from: normalized.index(after: dot), to: normalized.endIndex)
            if frac > exp { return nil }
        }
        if normalized.hasSuffix(".") { normalized.removeLast() }
        guard !normalized.isEmpty,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return minorUnits(from: value, currencyCode: currencyCode)
    }

    /// Double for chart plotting ONLY. Never use for arithmetic or stored values.
    static func plotValue(_ minor: Int64, currencyCode: String) -> Double {
        NSDecimalNumber(decimal: decimal(fromMinorUnits: minor, currencyCode: currencyCode)).doubleValue
    }

    static func format(_ minor: Int64, currencyCode: String, locale: Locale = .current) -> String {
        decimal(fromMinorUnits: minor, currencyCode: currencyCode)
            .formatted(.currency(code: currencyCode).locale(locale))
    }
}
