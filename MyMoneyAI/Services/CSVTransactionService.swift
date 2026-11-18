import Foundation
import SwiftData

// MARK: - Dates

/// Field order for all-numeric dates. Dates with a month name ("5 Jan 2024", "Jan 5, 2024") parse in any order.
enum CSVDateOrder: String, CaseIterable, Identifiable, Sendable, Codable {
    case yearMonthDay, monthDayYear, dayMonthYear
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .yearMonthDay: "Year-Month-Day (2024-01-31)"
        case .monthDayYear: "Month/Day/Year (01/31/2024)"
        case .dayMonthYear: "Day/Month/Year (31/01/2024)"
        }
    }
}

enum CSVDateParser {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Parses the date part of a cell (any time after a space or "T" is ignored) to noon on that
    /// day in `calendar`, so time-zone and DST shifts never move it to another day.
    static func parse(_ raw: String, order: CSVDateOrder, calendar: Calendar) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let t = s.firstIndex(of: "T"), s[..<t].count == 10 { s = String(s[..<t]) }
        let tokens = s.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        guard tokens.count >= 3 else { return nil }

        var y: Int?, m: Int?, d: Int?
        if let nameIndex = tokens.prefix(3).firstIndex(where: { $0.first?.isLetter == true }) {
            let name = tokens[nameIndex].lowercased()
            guard name.count >= 3, let mi = months.firstIndex(of: String(name.prefix(3))) else { return nil }
            m = mi + 1
            let numbers = tokens.prefix(3).enumerated().filter { $0.offset != nameIndex }.map(\.element)
            guard numbers.count == 2, let a = Int(numbers[0]), let b = Int(numbers[1]) else { return nil }
            if numbers[0].count == 4 { y = a; d = b } else { d = a; y = b; if numbers[1].count == 2 { y = 2000 + b } }
        } else {
            let fields = tokens.prefix(3)
            guard fields.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
            let n = fields.compactMap { Int($0) }
            guard n.count == 3 else { return nil }
            let lens = fields.map(\.count)
            switch order {
            case .yearMonthDay:
                guard lens[0] == 4 else { return nil }
                (y, m, d) = (n[0], n[1], n[2])
            case .monthDayYear:
                guard lens[2] == 4 || lens[2] == 2 else { return nil }
                (m, d, y) = (n[0], n[1], lens[2] == 2 ? 2000 + n[2] : n[2])
            case .dayMonthYear:
                guard lens[2] == 4 || lens[2] == 2 else { return nil }
                (d, m, y) = (n[0], n[1], lens[2] == 2 ? 2000 + n[2] : n[2])
            }
        }
        guard let year = y, let month = m, let day = d, (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let comps = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: comps), calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    /// Orders that read the most samples (a few bad rows don't hide the format). Year-first wins
    /// when possible; when month-first and day-first read equally many, the region decides which comes first.
    static func candidateOrders(samples: [String], calendar: Calendar, locale: Locale) -> [CSVDateOrder] {
        let counts = parseCounts(samples: samples, calendar: calendar)
        let best = counts.values.max() ?? 0
        guard best > 0 else { return [] }
        let monthFirstRegions: Set<String> = ["US", "PH", "PR", "GU", "AS", "UM", "VI", "FM", "MH", "PW", "BZ"]
        let region = locale.region?.identifier ?? ""
        let preferred: [CSVDateOrder] = monthFirstRegions.contains(region)
            ? [.yearMonthDay, .monthDayYear, .dayMonthYear] : [.yearMonthDay, .dayMonthYear, .monthDayYear]
        return preferred.filter { counts[$0] == best }
    }

    /// How many non-empty samples each order reads.
    static func parseCounts(samples: [String], calendar: Calendar) -> [CSVDateOrder: Int] {
        let values = samples.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var counts: [CSVDateOrder: Int] = [:]
        for order in CSVDateOrder.allCases {
            counts[order] = values.filter { parse($0, order: order, calendar: calendar) != nil }.count
        }
        return counts
    }
}

// MARK: - Amounts

enum CSVAmountParser {
    /// Signed minor units from a bank amount cell. Understands "-12.50", "(12.50)", "12.50-",
    /// "12.50 CR" / "12.50 DR", "+12.50", currency symbols and codes, and grouping separators.
    /// Returns nil when the cell is empty or not a number.
    static func parse(_ raw: String, currencyCode: String) -> Int64? {
        var s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{2212}", with: "-")
        guard s.contains(where: { $0.isASCII && $0.isNumber }) else { return nil }
        var negative = false
        let upper = s.uppercased()
        if upper.hasSuffix("CR") { s = String(s.dropLast(2)) }
        else if upper.hasSuffix("DR") { s = String(s.dropLast(2)); negative = true }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("("), s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        if s.hasSuffix("-") { negative = true; s.removeLast() }
        if let i = s.firstIndex(of: "-") {
            // Only a leading sign is accepted (possibly after a currency symbol); "12-50" is not a number.
            guard !s[..<i].contains(where: \.isNumber) else { return nil }
            negative = true
            s.remove(at: i)
        }
        s = s.replacingOccurrences(of: "+", with: "")
        // Letters are allowed only as a currency code or symbol around the number, not inside it.
        let digitsAndSeparators = s.filter { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," || $0 == " " || $0 == "'" || $0 == "\u{00A0}" }
        guard let first = digitsAndSeparators.firstIndex(where: \.isNumber),
              let last = digitsAndSeparators.lastIndex(where: \.isNumber) else { return nil }
        let core = digitsAndSeparators[first...last].filter { $0 != " " && $0 != "'" && $0 != "\u{00A0}" }
        guard s.filter({ $0.isASCII && $0.isNumber }).count == core.filter(\.isNumber).count,
              let value = CurrencyMath.parse(String(core), currencyCode: currencyCode) else { return nil }
        return negative ? -value : value
    }
}

// MARK: - Mapping

enum CSVAmountMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case single, debitCredit
    var id: String { rawValue }
    var displayName: String { self == .single ? "One amount column" : "Separate debit and credit columns" }
}

/// Which column holds what. Column indexes refer to `CSVImportSource.columns`.
struct CSVColumnMapping: Equatable, Sendable, Codable {
    var date: Int?
    var description: Int?
    var amountMode: CSVAmountMode = .single
    var amount: Int?
    /// In single-column mode: true when money spent is negative (most banks), false when it's positive.
    var negativeIsExpense = true
    var debit: Int?
    var credit: Int?
    var merchant: Int?
    var category: Int?
    var notes: Int?
    /// MyMoney AI's own "Type" column (Income/Expense/Transfer/Adjustment). Overrides the sign.
    var type: Int?
    var refund: Int?
    /// MyMoney AI's own "Counts In Month" column ("2026-11").
    var countedMonth: Int?
    /// Running balance column. Read for reference only; it never changes an amount.
    var balance: Int?
    /// Status column; rows whose status says "pending" are marked pending.
    var status: Int?
    var dateOrder: CSVDateOrder = .yearMonthDay

    var isComplete: Bool {
        guard date != nil else { return false }
        switch amountMode {
        case .single: return amount != nil
        case .debitCredit: return debit != nil || credit != nil
        }
    }
}

/// A parsed file ready for mapping: header names (or "Column N") and data rows.
struct CSVImportSource: Equatable, Sendable {
    var columns: [String]
    var rows: [[String]]
    var lineNumbers: [Int]
    var hasHeaderRow: Bool

    init(table: CSVTable, hasHeaderRow: Bool) {
        let width = table.rows.map(\.count).max() ?? 0
        let padded = table.rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        self.hasHeaderRow = hasHeaderRow && padded.count > 0
        if self.hasHeaderRow {
            columns = padded[0].enumerated().map { i, name in
                let t = name.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? "Column \(i + 1)" : t
            }
            rows = Array(padded.dropFirst())
            lineNumbers = Array(table.lineNumbers.dropFirst())
        } else {
            columns = (0..<width).map { "Column \($0 + 1)" }
            rows = padded
            lineNumbers = table.lineNumbers
        }
    }

    /// A first row with no readable date and no amount anywhere is a header.
    static func looksLikeHeader(_ row: [String], calendar: Calendar) -> Bool {
        !row.contains { cell in
            CSVDateOrder.allCases.contains { CSVDateParser.parse(cell, order: $0, calendar: calendar) != nil }
                || (CSVAmountParser.parse(cell, currencyCode: "USD") != nil && cell.contains(where: { $0 == "." || $0 == "," }))
        }
    }

    func samples(column: Int?, limit: Int = 200) -> [String] {
        guard let column else { return [] }
        return rows.prefix(limit).map { column < $0.count ? $0[column] : "" }
    }

    /// Guesses columns from header names, then the date order from the date column's values.
    func suggestedMapping(calendar: Calendar, locale: Locale) -> CSVColumnMapping {
        var m = CSVColumnMapping()
        let names = columns.map { MerchantName.normalize($0) }
        func find(_ phrases: [String], excluding used: [Int?] = []) -> Int? {
            for p in phrases {
                if let i = names.firstIndex(where: { $0 == p }), !used.contains(i) { return i }
            }
            for p in phrases {
                if let i = names.firstIndex(where: { MerchantName.containsPhrase($0, p) }), !used.contains(i) { return i }
            }
            return nil
        }
        if hasHeaderRow {
            m.date = find(["date", "transaction date", "posting date", "posted date", "booking date", "value date", "posted", "txn date"])
            m.debit = find(["debit", "debit amount", "withdrawal", "withdrawals", "money out", "paid out", "spent", "outflow"])
            m.credit = find(["credit", "credit amount", "deposit", "deposits", "money in", "paid in", "received", "inflow"])
            m.amount = find(["amount", "signed amount", "transaction amount", "value", "net amount"], excluding: [m.debit, m.credit])
            m.description = find(["description", "title", "details", "transaction details", "narrative", "narration",
                                  "payee", "name", "particulars", "memo", "reference"], excluding: [m.date])
            m.merchant = find(["merchant", "merchant name"], excluding: [m.description])
            m.category = find(["category"])
            m.notes = find(["notes", "note"], excluding: [m.description])
            m.type = find(["type"]).flatMap { (i: Int) -> Int? in
                // Only MyMoney AI's own type values; a bank's "Type" column ("POS", "DD") is ignored.
                let values = samples(column: i).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                return !values.isEmpty && values.allSatisfy { CSVTransactionImporter.transactionType(from: $0) != nil } ? i : nil
            }
            m.refund = find(["refund"])
            m.countedMonth = find(["counts in month"])
            m.balance = find(["balance", "running balance", "available balance", "ledger balance"], excluding: [m.amount, m.debit, m.credit])
            m.status = find(["status", "transaction status", "pending"], excluding: [m.description])
            if m.amount == nil, m.debit != nil || m.credit != nil { m.amountMode = .debitCredit }
        }
        if m.date == nil {
            // The first column where at least half of the filled cells are dates.
            m.date = columns.indices.first { i in
                let values = samples(column: i).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let best = CSVDateParser.parseCounts(samples: values, calendar: calendar).values.max() ?? 0
                return best > 0 && best * 2 >= values.count
            }
        }
        if m.amountMode == .single, m.amount == nil {
            m.amount = columns.indices.last { i in
                i != m.date && samples(column: i).allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || CSVAmountParser.parse($0, currencyCode: "USD") != nil }
                    && samples(column: i).contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
        }
        if m.description == nil {
            m.description = columns.indices.first { $0 != m.date && $0 != m.amount && $0 != m.debit && $0 != m.credit }
        }
        if let order = CSVDateParser.candidateOrders(samples: samples(column: m.date), calendar: calendar, locale: locale).first {
            m.dateOrder = order
        }
        return m
    }
}

// MARK: - Import plan

struct CSVImportRow: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case new
        /// Matches a transaction already in the app (same day, type, amount and a compatible description).
        case duplicate(existingId: UUID)
        case invalid(String)
    }
    var id: Int { line }
    var line: Int
    var status: Status
    var record: TransactionRecord?
    var categorySuggested: Bool
    /// The bank hasn't posted it yet. Pending rows are skipped by default, because the posted
    /// version usually appears in the next export and would otherwise be counted twice.
    var isPending = false
}

struct CSVImportPlan: Equatable, Sendable {
    var rows: [CSVImportRow]

    var newCount: Int { rows.filter { $0.status == .new }.count }
    var duplicateCount: Int { rows.filter { if case .duplicate = $0.status { true } else { false } }.count }
    var invalidCount: Int { rows.filter { if case .invalid = $0.status { true } else { false } }.count }

    var pendingCount: Int { rows.filter { $0.isPending && $0.record != nil }.count }

    func recordsToImport(includeDuplicates: Bool, includePending: Bool = false) -> [TransactionRecord] {
        rows.compactMap { (row: CSVImportRow) -> TransactionRecord? in
            if row.isPending && !includePending { return nil }
            switch row.status {
            case .new: return row.record
            case .duplicate: return includeDuplicates ? row.record : nil
            case .invalid: return nil
            }
        }
    }
}

struct CSVImportOptions: Equatable, Sendable {
    var currencyCode: String
    var paymentMethodId: UUID?
}

/// Turns mapped CSV rows into transactions. Pure and deterministic: no storage access.
enum CSVTransactionImporter {
    static let maximumTitleLength = 200
    static let maximumNotesLength = 2_000

    static func transactionType(from raw: String) -> TransactionType? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return TransactionType.allCases.first { $0.rawValue == t || $0.displayName.lowercased() == t }
    }

    static func plan(source: CSVImportSource, mapping: CSVColumnMapping, options: CSVImportOptions,
                     categories: [CategoryOption], existing: [TransactionRecord],
                     suggester: any CategorySuggesting, calendar: Calendar, now: Date = .now) -> CSVImportPlan {
        var pool = DuplicatePool(existing: existing, calendar: calendar)
        var rows: [CSVImportRow] = []
        rows.reserveCapacity(source.rows.count)
        for (index, cells) in source.rows.enumerated() {
            let line = source.lineNumbers[index]
            func cell(_ i: Int?) -> String {
                guard let i, i < cells.count else { return "" }
                return cells[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            switch makeRecord(cell: cell, mapping: mapping, options: options, categories: categories,
                              history: existing, suggester: suggester, calendar: calendar, now: now) {
            case .failure(let reason):
                rows.append(CSVImportRow(line: line, status: .invalid(reason), record: nil, categorySuggested: false))
            case .success(let made):
                let pending = cell(mapping.status).lowercased().contains("pending")
                let status: CSVImportRow.Status = pending ? .new : (pool.take(matching: made.record).map { .duplicate(existingId: $0) } ?? .new)
                rows.append(CSVImportRow(line: line, status: status, record: made.record, categorySuggested: made.suggested, isPending: pending))
            }
        }
        return CSVImportPlan(rows: rows)
    }

    private struct Made { var record: TransactionRecord; var suggested: Bool }
    private enum Outcome { case success(Made), failure(String) }

    private static func makeRecord(cell: (Int?) -> String, mapping: CSVColumnMapping, options: CSVImportOptions,
                                   categories: [CategoryOption], history: [TransactionRecord],
                                   suggester: any CategorySuggesting, calendar: Calendar, now: Date) -> Outcome {
        let dateText = cell(mapping.date)
        guard !dateText.isEmpty else { return .failure("No date") }
        guard let date = CSVDateParser.parse(dateText, order: mapping.dateOrder, calendar: calendar) else {
            return .failure("Can't read the date \"\(dateText.prefix(30))\"")
        }

        var signed: Int64
        switch mapping.amountMode {
        case .single:
            let text = cell(mapping.amount)
            guard !text.isEmpty else { return .failure("No amount") }
            guard let v = CSVAmountParser.parse(text, currencyCode: options.currencyCode) else {
                return .failure("Can't read the amount \"\(text.prefix(30))\"")
            }
            signed = mapping.negativeIsExpense ? v : -v
        case .debitCredit:
            let debitText = cell(mapping.debit), creditText = cell(mapping.credit)
            let debit = debitText.isEmpty ? 0 : CSVAmountParser.parse(debitText, currencyCode: options.currencyCode)
            let credit = creditText.isEmpty ? 0 : CSVAmountParser.parse(creditText, currencyCode: options.currencyCode)
            guard let d = debit else { return .failure("Can't read the debit \"\(debitText.prefix(30))\"") }
            guard let c = credit else { return .failure("Can't read the credit \"\(creditText.prefix(30))\"") }
            if d != 0 && c != 0 { return .failure("Has both a debit and a credit") }
            signed = c != 0 ? abs(c) : -abs(d)
        }
        guard signed != 0 else { return .failure("Amount is zero") }
        guard signed != Int64.min else { return .failure("Amount is too large") }

        var type: TransactionType = signed < 0 ? .expense : .income
        var isRefund = false
        if mapping.type != nil {
            let typeText = cell(mapping.type)
            guard let t = transactionType(from: typeText) else { return .failure("Unknown type \"\(typeText.prefix(30))\"") }
            type = t
            isRefund = ["yes", "true", "1", "y"].contains(cell(mapping.refund).lowercased())
        }

        let description = String(cell(mapping.description).prefix(maximumTitleLength))
        let merchantText = String(cell(mapping.merchant).prefix(maximumTitleLength))
        let title = description.isEmpty ? (merchantText.isEmpty ? "Imported transaction" : merchantText) : description
        let notes = String(cell(mapping.notes).prefix(maximumNotesLength))

        var categoryId: UUID?
        var suggested = false
        if let kind = type.categoryKind {
            let name = cell(mapping.category)
            if !name.isEmpty {
                categoryId = categories.first { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
            }
            if categoryId == nil, let s = suggester.suggest(merchant: merchantText.isEmpty ? title : merchantText, receiptText: nil,
                                                            kind: kind, categories: categories, history: history) {
                categoryId = s.categoryId
                suggested = true
            }
        }

        var countedMonth: Int?
        let countedText = cell(mapping.countedMonth)
        if type.categoryKind != nil, !countedText.isEmpty {
            let parts = countedText.split { !$0.isNumber }.compactMap { Int($0) }
            let k = parts.count == 2 ? CountedMonth.key(year: parts[0], month: parts[1]) : 0
            guard parts.count == 2, CountedMonth.date(forKey: k, calendar: calendar) != nil else {
                return .failure("Can't read the month \"\(countedText.prefix(30))\"")
            }
            countedMonth = k == CountedMonth.key(for: date, calendar: calendar) ? nil : k
        }

        let record = TransactionRecord(
            transactionDate: date, createdAt: now, updatedAt: now, amountMinorUnits: abs(signed),
            currencyCode: options.currencyCode, merchant: merchantText.isEmpty ? nil : merchantText, title: title,
            notes: notes.isEmpty ? nil : notes, transactionType: type, categoryId: categoryId,
            paymentMethodId: options.paymentMethodId, source: .csvImport, isVerified: true, isRefund: isRefund,
            countedMonth: countedMonth)
        return .success(Made(record: record, suggested: suggested))
    }

    /// Existing transactions that a CSV row can match. Each existing transaction matches at most
    /// one row, so two identical coffees on the same day in the file stay two transactions when
    /// only one of them is already in the app.
    private struct DuplicatePool {
        struct Key: Hashable { var day: Date; var type: TransactionType; var amount: Int64; var currency: String }
        var entries: [Key: [(id: UUID, names: [String])]] = [:]
        let calendar: Calendar

        init(existing: [TransactionRecord], calendar: Calendar) {
            self.calendar = calendar
            for r in existing.sorted(by: { $0.createdAt < $1.createdAt }) {
                // Either the merchant or the title can match.
                let names = [r.merchant, r.title].compactMap { $0 }.map { MerchantName.normalize($0) }.filter { !$0.isEmpty }
                entries[Self.key(r, calendar), default: []].append((r.id, names))
            }
        }

        static func key(_ r: TransactionRecord, _ calendar: Calendar) -> Key {
            Key(day: calendar.startOfDay(for: r.transactionDate), type: r.transactionType, amount: r.amountMinorUnits, currency: r.currencyCode)
        }

        mutating func take(matching r: TransactionRecord) -> UUID? {
            let k = Self.key(r, calendar)
            guard var list = entries[k], !list.isEmpty else { return nil }
            let names = [r.title, r.merchant].compactMap { $0 }.map { MerchantName.normalize($0) }.filter { !$0.isEmpty }
            let index = list.firstIndex { entry in
                let existingNames = entry.names
                if names.isEmpty || existingNames.isEmpty { return true }
                return names.contains { n in existingNames.contains { e in e == n || e.contains(n) || n.contains(e) } }
            }
            guard let i = index else { return nil }
            let id = list.remove(at: i).id
            entries[k] = list
            return id
        }
    }
}

// MARK: - Export

enum CSVTransactionExporter {
    static let header = ["Date", "Type", "Refund", "Title", "Merchant", "Category", "Payment Method",
                         "Amount", "Signed Amount", "Currency", "Notes", "Source", "Counts In Month"]

    /// One row per transaction, oldest first. "Amount" is always positive and "Type" gives the
    /// direction; "Signed Amount" is negative for money out, for spreadsheet sums.
    /// Amounts use "." as the decimal separator and no grouping, so they re-import exactly.
    static func csv(records: [TransactionRecord], categoryNames: [UUID: String], paymentMethodNames: [UUID: String],
                    calendar: Calendar) -> String {
        let sorted = records.sorted { ($0.transactionDate, $0.createdAt, $0.id.uuidString) < ($1.transactionDate, $1.createdAt, $1.id.uuidString) }
        var rows = [header]
        for r in sorted {
            let c = calendar.dateComponents([.year, .month, .day], from: r.transactionDate)
            let date = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            let amount = plainAmount(r.amountMinorUnits, currencyCode: r.currencyCode)
            let signed: String
            switch r.transactionType {
            case .income: signed = r.isRefund ? "-" + amount : amount
            case .expense: signed = r.isRefund ? amount : "-" + amount
            case .transfer, .adjustment: signed = amount
            }
            rows.append([
                date, r.transactionType.displayName, r.isRefund ? "Yes" : "",
                CSVWriter.textCell(r.title), CSVWriter.textCell(r.merchant ?? ""),
                CSVWriter.textCell(r.categoryId.flatMap { categoryNames[$0] } ?? ""),
                CSVWriter.textCell(r.paymentMethodId.flatMap { paymentMethodNames[$0] } ?? ""),
                amount, signed, r.currencyCode, CSVWriter.textCell(r.notes ?? ""), r.source.displayName,
                countedMonthText(r, calendar: calendar),
            ])
        }
        return CSVWriter.write(rows)
    }

    /// "2026-11" when the transaction counts in a month other than its date's, otherwise empty.
    static func countedMonthText(_ r: TransactionRecord, calendar: Calendar) -> String {
        guard r.isCountedInOtherMonth(calendar: calendar), let k = r.countedMonth else { return "" }
        return String(format: "%04d-%02d", k / 100, k % 100)
    }

    /// "1234.50" for USD, "1234" for JPY, "1.234" for KWD.
    static func plainAmount(_ minor: Int64, currencyCode: String) -> String {
        let exp = CurrencyMath.exponent(for: currencyCode)
        let magnitude = minor.magnitude
        guard exp > 0 else { return String(magnitude) }
        var divisor: UInt64 = 1
        for _ in 0..<exp { divisor *= 10 }
        let fraction = String(magnitude % divisor)
        return "\(minor < 0 ? "-" : "")\(magnitude / divisor).\(String(repeating: "0", count: exp - fraction.count))\(fraction)"
    }
}
