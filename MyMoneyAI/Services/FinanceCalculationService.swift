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

/// Deterministic financial calculations over stored records. Phase 1 provides the period summary;
/// category, payment-method, trend and budget calculations arrive in Phase 3.
struct FinanceCalculationService: Sendable {
    var calendar: Calendar = .current

    /// Rules:
    /// - Range is start-inclusive, end-exclusive, on `transactionDate` (not `createdAt`).
    /// - Only records in `currencyCode` are summed; other currencies are counted as excluded.
    /// - Transfers (incl. credit-card repayments) and adjustments are never income or expense,
    ///   so a card purchase (expense) plus its repayment (transfer) counts once.
    /// - `isRefund` subtracts within its bucket.
    func summary(of records: [TransactionRecord], in range: DateRange, currencyCode: String) -> PeriodSummary {
        var s = PeriodSummary(currencyCode: currencyCode)
        for r in records where range.contains(r.transactionDate) {
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
}
