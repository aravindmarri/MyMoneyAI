import Foundation

/// How sure the parser is about an extracted value. Nothing is ever saved without user review;
/// the UI uses this to flag fields that most need checking.
enum ParseConfidence: Int, Comparable, Sendable {
    case low = 0, medium, high
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .low: "Check"
        case .medium: "Likely"
        case .high: "Confident"
        }
    }
}

struct ParsedValue<Value: Sendable & Equatable>: Sendable, Equatable {
    var value: Value
    var confidence: ParseConfidence
}

struct AmountCandidate: Hashable, Sendable {
    enum Kind: String, Sendable {
        case grandTotal, total, amountDue, subtotal, tax, discount, tip, payment, change, tendered, unlabeled
    }
    var kind: Kind
    var minorUnits: Int64
    var lineIndex: Int
}

struct ParsedReceipt: Sendable, Equatable {
    var merchant: ParsedValue<String>?
    var date: ParsedValue<Date>?
    var total: ParsedValue<Int64>?
    var subtotalMinorUnits: Int64?
    var taxMinorUnits: Int64?
    var discountMinorUnits: Int64?
    var currencyCode: ParsedValue<String>?
    var candidates: [AmountCandidate] = []
    var lines: [String] = []
}

/// Deterministic receipt text parser. No machine learning, no network: rules only, so results are
/// reproducible and testable. Handles labels and amounts on the same line, labels and amounts split
/// into separate lines (common when OCR reads columns separately), subtotal + tax − discount
/// reconciliation, and change/cash lines that must never be mistaken for the total.
struct ReceiptParserService: Sendable {
    var calendar: Calendar = .current
    var referenceDate: Date = .now

    static let isoDatePattern = #"\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b"#
    static let numericDatePattern = #"\b(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})\b"#
    static let monthFirstPattern = #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#
    static let dayFirstPattern = #"\b(\d{1,2})\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+(\d{4})\b"#
    /// Money with exactly two decimals: 12.34, 1,234.56, 1.234,56, 12,34. Not followed by % (tax rates).
    static let amountPattern = #"(?<![\d.,])(\d{1,3}(?:,\d{3})+|\d{1,3}(?:\.\d{3})+|\d+)[.,](\d{2})(?!\d)(?!\s?%)"#
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    func parse(text: String, defaultCurrency: String) -> ParsedReceipt {
        parse(lines: text.components(separatedBy: .newlines), defaultCurrency: defaultCurrency)
    }

    func parse(lines rawLines: [String], defaultCurrency: String) -> ParsedReceipt {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var result = ParsedReceipt(lines: lines)
        result.currencyCode = detectCurrency(lines, defaultCurrency: defaultCurrency)
        let code = result.currencyCode?.value ?? defaultCurrency
        result.date = detectDate(lines)
        result.merchant = detectMerchant(lines)

        let candidates = amountCandidates(lines, currencyCode: code)
        result.candidates = candidates
        let subtotalCandidate = candidates.last { $0.kind == .subtotal }
        let taxes = candidates.filter { $0.kind == .tax }.map(\.minorUnits)
        let discountCandidates = candidates.filter { $0.kind == .discount }
        let tips = candidates.filter { $0.kind == .tip }.map(\.minorUnits)
        result.subtotalMinorUnits = subtotalCandidate?.minorUnits
        result.taxMinorUnits = taxes.isEmpty ? nil : taxes.reduce(0, +)
        result.discountMinorUnits = discountCandidates.isEmpty ? nil : discountCandidates.map(\.minorUnits).reduce(0, +)

        // Receipts print the subtotal either before or after discounts. Accept both when checking a
        // printed total; when inferring a total, discounts listed above the subtotal are already in it.
        var expected: [Int64] = []
        if let sub = subtotalCandidate {
            let base = sub.minorUnits + (result.taxMinorUnits ?? 0) + tips.reduce(0, +)
            let discount = result.discountMinorUnits ?? 0
            let discountAlreadyApplied = discountCandidates.allSatisfy { $0.lineIndex < sub.lineIndex }
            expected = discountAlreadyApplied ? [base, base - discount] : [base - discount, base]
        }
        result.total = selectTotal(candidates, expected: expected)
        return result
    }

    // MARK: - Amounts

    func amountCandidates(_ lines: [String], currencyCode: String) -> [AmountCandidate] {
        var result: [AmountCandidate] = []
        var pendingKinds: [AmountCandidate.Kind] = []
        for (i, line) in lines.enumerated() {
            let kind = classify(line)
            let values = amountValues(maskDates(line), currencyCode: currencyCode)
            if let value = values.last {
                var k = kind
                if k == .unlabeled, !pendingKinds.isEmpty { k = pendingKinds.removeFirst() }
                result.append(AmountCandidate(kind: k, minorUnits: value, lineIndex: i))
            } else if kind != .unlabeled {
                pendingKinds.append(kind)   // label without amount: pair with the next bare amount(s)
            }
        }
        return result
    }

    func classify(_ line: String) -> AmountCandidate.Kind {
        let l = line.lowercased()
            .replacingOccurrences(of: "t0tal", with: "total")
            .replacingOccurrences(of: "tota1", with: "total")
        func has(_ s: String) -> Bool { l.contains(s) }
        func word(_ w: String) -> Bool { !Self.matches(#"\b\#(w)\b"#, in: l).isEmpty }

        if has("change") && !has("exchange") { return .change }
        if has("tender") || word("cash") { return .tendered }
        if word("tip") || has("gratuity") { return .tip }
        if has("subtotal") || has("sub total") || has("sub-total") || has("before tax") || has("pre-tax") { return .subtotal }
        if (word("tax") || word("vat") || word("gst") || word("hst") || word("pst")) && !has("incl") { return .tax }
        if has("discount") || has("saving") || has("coupon") || has("you saved") || has("promo") { return .discount }
        if has("grand total") { return .grandTotal }
        if has("amount due") || has("balance due") || has("total due") || has("amount payable") { return .amountDue }
        if word("total") { return .total }
        if word("visa") || has("mastercard") || word("amex") || has("discover") || word("debit") || word("credit")
            || word("card") || word("paid") || has("apple pay") || has("payment") { return .payment }
        return .unlabeled
    }

    func amountValues(_ text: String, currencyCode: String) -> [Int64] {
        Self.matches(Self.amountPattern, in: text, caseInsensitive: false).compactMap { m in
            guard let whole = Self.group(m, 1, in: text), let cents = Self.group(m, 2, in: text),
                  let value = Decimal(string: "\(whole.filter(\.isNumber)).\(cents)", locale: Locale(identifier: "en_US_POSIX"))
            else { return nil }
            return CurrencyMath.minorUnits(from: value, currencyCode: currencyCode)
        }
    }

    /// - Parameter expected: totals implied by subtotal/tax/discount/tip, most likely first.
    func selectTotal(_ c: [AmountCandidate], expected: [Int64]) -> ParsedValue<Int64>? {
        let payments = c.filter { $0.kind == .payment }.map(\.minorUnits)
        for kind in [AmountCandidate.Kind.grandTotal, .amountDue, .total] {
            let group = c.filter { $0.kind == kind }.map(\.minorUnits)
            guard let largest = group.max() else { continue }
            if let e = expected.first(where: { group.contains($0) }) { return ParsedValue(value: e, confidence: .high) }
            if let p = group.first(where: { payments.contains($0) }) { return ParsedValue(value: p, confidence: .high) }
            return ParsedValue(value: largest, confidence: .medium)
        }
        if let e = expected.first, e > 0 { return ParsedValue(value: e, confidence: .medium) }
        if let p = payments.max() { return ParsedValue(value: p, confidence: .medium) }
        return c.filter { $0.kind == .unlabeled }.map(\.minorUnits).max().map { ParsedValue(value: $0, confidence: .low) }
    }

    // MARK: - Merchant

    func detectMerchant(_ lines: [String]) -> ParsedValue<String>? {
        let skipWords = ["receipt", "invoice", "tel", "phone", "fax", "reg", "order", "date", "time", "table", "server",
                         "guest", "cashier", "terminal", "store", "copy", "transaction", "trans", "ticket", "check"]
        let skipFragments = ["thank", "www", "http", ".com", "@", "#"]
        for (i, raw) in lines.prefix(8).enumerated() {
            var line = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            if line.lowercased().hasPrefix("welcome to ") { line = String(line.dropFirst("welcome to ".count)) }
            let lower = line.lowercased()
            let letters = line.filter(\.isLetter).count
            let nonSpace = line.filter { !$0.isWhitespace }.count
            guard letters >= 3, nonSpace > 0, Double(letters) / Double(nonSpace) >= 0.6 else { continue }
            if skipFragments.contains(where: { lower.contains($0) }) { continue }
            if skipWords.contains(where: { !Self.matches(#"\b\#($0)\b"#, in: lower).isEmpty }) { continue }
            if lower.hasPrefix("welcome") { continue }
            if !amountValues(line, currencyCode: "USD").isEmpty || !dateRanges(in: line).isEmpty { continue }
            if !Self.matches(#"^\d+\s+\w+"#, in: line).isEmpty { continue }   // street address
            return ParsedValue(value: Self.cleanMerchant(line), confidence: i <= 1 ? .medium : .low)
        }
        return nil
    }

    static func cleanMerchant(_ s: String) -> String {
        let collapsed = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let allCaps = collapsed == collapsed.uppercased() && collapsed.contains(where: \.isLetter)
        return String((allCaps ? collapsed.capitalized : collapsed).prefix(60))
    }

    // MARK: - Date

    func detectDate(_ lines: [String]) -> ParsedValue<Date>? {
        for line in lines {
            if let d = firstDate(in: line) { return d }
        }
        return nil
    }

    private func firstDate(in s: String) -> ParsedValue<Date>? {
        if let m = Self.matches(Self.isoDatePattern, in: s).first,
           let y = Self.int(m, 1, s), let mo = Self.int(m, 2, s), let d = Self.int(m, 3, s),
           let date = makeDate(y, mo, d) {
            return ParsedValue(value: date, confidence: .high)
        }
        if let m = Self.matches(Self.monthFirstPattern, in: s).first,
           let mo = Self.monthIndex(Self.group(m, 1, in: s)), let d = Self.int(m, 2, s), let y = Self.int(m, 3, s),
           let date = makeDate(y, mo, d) {
            return ParsedValue(value: date, confidence: .high)
        }
        if let m = Self.matches(Self.dayFirstPattern, in: s).first,
           let d = Self.int(m, 1, s), let mo = Self.monthIndex(Self.group(m, 2, in: s)), let y = Self.int(m, 3, s),
           let date = makeDate(y, mo, d) {
            return ParsedValue(value: date, confidence: .high)
        }
        for m in Self.matches(Self.numericDatePattern, in: s) {
            guard let a = Self.int(m, 1, s), let b = Self.int(m, 2, s), let yRaw = Self.int(m, 3, s) else { continue }
            let year = yRaw < 100 ? 2000 + yRaw : yRaw
            var month = a, day = b
            var confidence = ParseConfidence.high
            if a > 12 && b <= 12 {
                month = b; day = a                          // unambiguous day-first
            } else if a <= 12 && b <= 12 && a != b {
                confidence = .medium                        // ambiguous: assume US month-first
            }
            if yRaw < 100 { confidence = min(confidence, .medium) }
            if let date = makeDate(year, month, day) { return ParsedValue(value: date, confidence: confidence) }
        }
        return nil
    }

    /// Noon local time avoids the date shifting across midnight in other time zones. Rejects impossible
    /// dates (Feb 30) and dates more than a day in the future or ten years in the past.
    private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        guard (1...12).contains(m), (1...31).contains(d),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)),
              calendar.component(.month, from: date) == m, calendar.component(.day, from: date) == d,
              let latest = calendar.date(byAdding: .day, value: 1, to: referenceDate),
              let earliest = calendar.date(byAdding: .year, value: -10, to: referenceDate),
              date <= latest, date >= earliest else { return nil }
        return date
    }

    func dateRanges(in s: String) -> [NSRange] {
        [Self.isoDatePattern, Self.monthFirstPattern, Self.dayFirstPattern, Self.numericDatePattern]
            .flatMap { Self.matches($0, in: s).map(\.range) }
    }

    private func maskDates(_ s: String) -> String {
        let ns = NSMutableString(string: s)
        for r in dateRanges(in: s) {
            ns.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        return ns as String
    }

    // MARK: - Currency

    func detectCurrency(_ lines: [String], defaultCurrency: String) -> ParsedValue<String>? {
        let text = lines.joined(separator: " ")
        if let m = Self.matches(#"\b(USD|EUR|GBP|CAD|AUD|INR|JPY)\b"#, in: text, caseInsensitive: false).first,
           let code = Self.group(m, 1, in: text) {
            return ParsedValue(value: code, confidence: .high)
        }
        for (symbol, code) in [("€", "EUR"), ("£", "GBP"), ("₹", "INR"), ("¥", "JPY")] where text.contains(symbol) {
            return ParsedValue(value: code, confidence: .medium)
        }
        if text.contains("$") {
            let dollar = ["USD", "CAD", "AUD"].contains(defaultCurrency) ? defaultCurrency : "USD"
            return ParsedValue(value: dollar, confidence: .low)
        }
        return nil
    }

    // MARK: - Regex helpers

    static func matches(_ pattern: String, in s: String, caseInsensitive: Bool = true) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        guard let r = Range(m.range(at: i), in: s) else { return nil }
        return String(s[r])
    }

    private static func int(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> Int? {
        group(m, i, in: s).flatMap { Int($0) }
    }

    private static func monthIndex(_ name: String?) -> Int? {
        guard let n = name?.lowercased().prefix(3) else { return nil }
        return months.firstIndex(of: String(n)).map { $0 + 1 }
    }
}
