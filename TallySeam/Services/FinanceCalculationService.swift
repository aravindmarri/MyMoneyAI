import Foundation

struct PeriodSummary: Equatable, Sendable {
    var currencyCode: String
    var incomeMinorUnits: Int64 = 0
    var expenseMinorUnits: Int64 = 0
    var transactionCount = 0
    /// Transactions in the range but in another currency — excluded, never converted.
    var excludedOtherCurrencyCount = 0

    /// Recognized income minus expenses. This is cash flow, NOT a bank balance or net worth.
    var netCashFlowMinorUnits: Int64 { incomeMinorUnits - expenseMinorUnits }

    /// Expenses ÷ income, or nil when there is no income.
    var expenseToIncomeRatio: Decimal? {
        incomeMinorUnits > 0 ? Decimal(expenseMinorUnits) / Decimal(incomeMinorUnits) : nil
    }
}

/// Net expense for one grouping key (category or payment method). `key == nil` means unassigned.
struct GroupTotal: Identifiable, Hashable, Sendable {
    var key: UUID?
    var minorUnits: Int64
    var id: String { key?.uuidString ?? "unassigned" }
}

struct MerchantTotal: Identifiable, Hashable, Sendable {
    var name: String
    var minorUnits: Int64
    var count: Int
    var id: String { name.lowercased() }
}

struct DailyTotal: Identifiable, Hashable, Sendable {
    var day: Date
    var minorUnits: Int64
    var id: Date { day }
}

struct MonthlyFlow: Identifiable, Hashable, Sendable {
    var monthStart: Date
    var incomeMinorUnits: Int64
    var expenseMinorUnits: Int64
    var netMinorUnits: Int64 { incomeMinorUnits - expenseMinorUnits }
    var id: Date { monthStart }
}

struct PeriodComparison: Equatable, Sendable {
    var current: PeriodSummary
    var previous: PeriodSummary

    /// Relative change in expenses vs. the previous period (0.1 = +10%); nil when the previous period had none.
    var expenseChange: Decimal? {
        guard previous.expenseMinorUnits > 0 else { return nil }
        return Decimal(current.expenseMinorUnits - previous.expenseMinorUnits) / Decimal(previous.expenseMinorUnits)
    }
    var incomeChange: Decimal? {
        guard previous.incomeMinorUnits > 0 else { return nil }
        return Decimal(current.incomeMinorUnits - previous.incomeMinorUnits) / Decimal(previous.incomeMinorUnits)
    }
}

/// Deterministic financial calculations over stored records. Every result is reproducible from
/// stored transactions alone; bills and receipts are never read.
struct FinanceCalculationService: Sendable {
    var calendar: Calendar = .current

    /// Rules:
    /// - Range is start-inclusive, end-exclusive, on the reporting date: `transactionDate`, or the
    ///   first of `countedMonth` when a transaction counts in another month (never `createdAt`).
    /// - Only records in `currencyCode` are summed; other currencies are counted as excluded.
    /// - Transfers (incl. credit-card repayments) and adjustments are never income or expense,
    ///   so a card purchase (expense) plus its repayment (transfer) counts once.
    /// - `isRefund` subtracts within its bucket.
    func summary(of records: [TransactionRecord], in range: DateRange, currencyCode: String) -> PeriodSummary {
        var s = PeriodSummary(currencyCode: currencyCode)
        for r in records where range.contains(r.reportingDate(in: calendar)) {
            guard r.currencyCode == currencyCode else { s.excludedOtherCurrencyCount += 1; continue }
            s.transactionCount += 1
            let signed = r.isRefund ? -r.amountMinorUnits : r.amountMinorUnits
            switch r.transactionType {
            case .income: s.incomeMinorUnits += signed
            case .expense: s.expenseMinorUnits += signed
            case .transfer, .adjustment: break
            }
        }
        return s
    }

    // MARK: - Breakdowns (expenses only, net of refunds)

    /// Signed expense contribution, or nil if the record isn't an in-range expense in this currency.
    private func expenseContribution(_ r: TransactionRecord, range: DateRange, currencyCode: String) -> Int64? {
        guard r.transactionType == .expense, r.currencyCode == currencyCode, range.contains(r.reportingDate(in: calendar)) else { return nil }
        return r.isRefund ? -r.amountMinorUnits : r.amountMinorUnits
    }

    private func groupedExpenses(_ records: [TransactionRecord], range: DateRange, currencyCode: String,
                                 key: (TransactionRecord) -> UUID?) -> [GroupTotal] {
        var totals: [UUID?: Int64] = [:]
        for r in records {
            guard let v = expenseContribution(r, range: range, currencyCode: currencyCode) else { continue }
            totals[key(r), default: 0] += v
        }
        return totals.filter { $0.value > 0 }
            .map { GroupTotal(key: $0.key, minorUnits: $0.value) }
            .sorted { $0.minorUnits != $1.minorUnits ? $0.minorUnits > $1.minorUnits : $0.id < $1.id }
    }

    /// Net spending per category, largest first. Categories whose refunds offset all spending are omitted.
    func expensesByCategory(_ records: [TransactionRecord], in range: DateRange, currencyCode: String) -> [GroupTotal] {
        groupedExpenses(records, range: range, currencyCode: currencyCode) { $0.categoryId }
    }

    /// Net spending per payment method (the channel used, e.g. Apple Pay), largest first.
    func expensesByPaymentMethod(_ records: [TransactionRecord], in range: DateRange, currencyCode: String) -> [GroupTotal] {
        groupedExpenses(records, range: range, currencyCode: currencyCode) { $0.paymentMethodId }
    }

    /// Top merchants by net spending. Merchant names are matched case-insensitively after trimming;
    /// records without a merchant fall back to their title.
    func topMerchants(_ records: [TransactionRecord], in range: DateRange, currencyCode: String, limit: Int = 5) -> [MerchantTotal] {
        var totals: [String: MerchantTotal] = [:]
        for r in records {
            guard let v = expenseContribution(r, range: range, currencyCode: currencyCode) else { continue }
            let raw = (r.merchant ?? r.title).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let key = raw.lowercased()
            var entry = totals[key] ?? MerchantTotal(name: raw, minorUnits: 0, count: 0)
            entry.minorUnits += v
            entry.count += 1
            totals[key] = entry
        }
        return totals.values.filter { $0.minorUnits > 0 }
            .sorted { $0.minorUnits != $1.minorUnits ? $0.minorUnits > $1.minorUnits : $0.id < $1.id }
            .prefix(max(0, limit)).map { $0 }
    }

    /// Net spending for every calendar day in the range, including days with no spending.
    func dailyExpenses(_ records: [TransactionRecord], in range: DateRange, currencyCode: String) -> [DailyTotal] {
        var byDay: [Date: Int64] = [:]
        for r in records {
            guard let v = expenseContribution(r, range: range, currencyCode: currencyCode) else { continue }
            byDay[calendar.startOfDay(for: r.reportingDate(in: calendar)), default: 0] += v
        }
        var result: [DailyTotal] = []
        var day = calendar.startOfDay(for: range.start)
        while day < range.end {
            result.append(DailyTotal(day: day, minorUnits: byDay[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }

    // MARK: - Trends

    /// Income and expenses for `count` consecutive calendar months ending with the month containing `date`, oldest first.
    func monthlyFlows(_ records: [TransactionRecord], endingWith date: Date, count: Int, currencyCode: String) -> [MonthlyFlow] {
        let lastStart = calendar.monthRange(containing: date).start
        return (0..<max(0, count)).reversed().map { offset in
            let range = calendar.monthRange(containing: calendar.addingMonths(-offset, to: lastStart))
            let s = summary(of: records, in: range, currencyCode: currencyCode)
            return MonthlyFlow(monthStart: range.start, incomeMinorUnits: s.incomeMinorUnits, expenseMinorUnits: s.expenseMinorUnits)
        }
    }

    /// Monthly flows covering an arbitrary range (every month the range touches), oldest first.
    func monthlyFlows(_ records: [TransactionRecord], in range: DateRange, currencyCode: String) -> [MonthlyFlow] {
        guard range.end > range.start else { return [] }
        let first = calendar.monthRange(containing: range.start).start
        let lastInstant = range.end.addingTimeInterval(-1)
        let months = (calendar.dateComponents([.month], from: first, to: calendar.monthRange(containing: lastInstant).start).month ?? 0) + 1
        return monthlyFlows(records, endingWith: lastInstant, count: months, currencyCode: currencyCode).map { flow in
            // Clip the first/last month to the requested range so totals match the range summary.
            let monthRange = calendar.monthRange(containing: flow.monthStart)
            let clipped = DateRange(start: max(monthRange.start, range.start), end: min(monthRange.end, range.end))
            let s = summary(of: records, in: clipped, currencyCode: currencyCode)
            return MonthlyFlow(monthStart: flow.monthStart, incomeMinorUnits: s.incomeMinorUnits, expenseMinorUnits: s.expenseMinorUnits)
        }
    }

    /// The month containing `date` compared with the month before it.
    func monthOverMonth(_ records: [TransactionRecord], month date: Date, currencyCode: String) -> PeriodComparison {
        let current = calendar.monthRange(containing: date)
        let previous = calendar.monthRange(containing: calendar.addingMonths(-1, to: current.start))
        return PeriodComparison(current: summary(of: records, in: current, currencyCode: currencyCode),
                                previous: summary(of: records, in: previous, currencyCode: currencyCode))
    }
}
