import Foundation

/// Value snapshot of a `Budget` for pure calculations.
struct BudgetRecord: Hashable, Sendable, Identifiable {
    var id: UUID
    /// nil = overall spending.
    var categoryId: UUID?
    var amountMinorUnits: Int64
    var currencyCode: String
    var effectiveStartMonth: Date
    var isActive: Bool

    init(id: UUID = UUID(), categoryId: UUID?, amountMinorUnits: Int64, currencyCode: String = CurrencyMath.defaultCode,
         effectiveStartMonth: Date, isActive: Bool = true) {
        self.id = id; self.categoryId = categoryId; self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode; self.effectiveStartMonth = effectiveStartMonth; self.isActive = isActive
    }
}

extension Budget {
    var record: BudgetRecord {
        BudgetRecord(id: id, categoryId: categoryId, amountMinorUnits: amountMinorUnits, currencyCode: currencyCode,
                     effectiveStartMonth: effectiveStartMonth, isActive: isActive)
    }
}

enum BudgetStatus: Equatable, Sendable {
    case onTrack, nearLimit, over
}

struct BudgetProgress: Identifiable, Hashable, Sendable {
    var budget: BudgetRecord
    /// Net expenses for the month (refunds subtracted). Can be negative if refunds exceed spending.
    var spentMinorUnits: Int64
    var id: UUID { budget.id }

    /// Negative when over budget.
    var remainingMinorUnits: Int64 { budget.amountMinorUnits - spentMinorUnits }

    /// Spent ÷ limit, never below 0. May exceed 1 when over budget.
    var fraction: Double {
        guard budget.amountMinorUnits > 0 else { return 0 }
        return max(0, Double(spentMinorUnits) / Double(budget.amountMinorUnits))
    }

    var status: BudgetStatus {
        if spentMinorUnits > budget.amountMinorUnits { return .over }
        // Integer comparison avoids floating-point edge cases: spent ≥ 80% of the limit.
        if spentMinorUnits * 5 >= budget.amountMinorUnits * 4 { return .nearLimit }
        return .onTrack
    }
}

/// Monthly budget progress from stored transactions. Uses the same rules as every other total:
/// expenses only, refunds subtract, transfers and adjustments never count, and only transactions
/// in the budget's own currency are included (no conversion).
struct BudgetCalculationService: Sendable {
    var finance: FinanceCalculationService

    init(finance: FinanceCalculationService = FinanceCalculationService()) { self.finance = finance }

    /// Active budgets that apply to the month containing `month`, overall budgets first,
    /// then by amount spent (largest first).
    func progress(budgets: [BudgetRecord], records: [TransactionRecord], month: Date) -> [BudgetProgress] {
        let range = finance.calendar.monthRange(containing: month)
        let applicable = budgets.filter { $0.isActive && finance.calendar.monthRange(containing: $0.effectiveStartMonth).start <= range.start }
        var byCurrency: [String: [UUID?: Int64]] = [:]
        var overall: [String: Int64] = [:]
        for code in Set(applicable.map(\.currencyCode)) {
            byCurrency[code] = Dictionary(uniqueKeysWithValues: finance.expensesByCategoryIncludingNegative(records, in: range, currencyCode: code))
            overall[code] = finance.summary(of: records, in: range, currencyCode: code).expenseMinorUnits
        }
        return applicable.map { b in
            let spent = b.categoryId.map { byCurrency[b.currencyCode]?[$0] ?? 0 } ?? overall[b.currencyCode] ?? 0
            return BudgetProgress(budget: b, spentMinorUnits: spent)
        }
        .sorted { a, b in
            if (a.budget.categoryId == nil) != (b.budget.categoryId == nil) { return a.budget.categoryId == nil }
            if a.spentMinorUnits != b.spentMinorUnits { return a.spentMinorUnits > b.spentMinorUnits }
            return a.id.uuidString < b.id.uuidString
        }
    }
}

extension FinanceCalculationService {
    /// Net expense per category including categories whose refunds exceed spending.
    func expensesByCategoryIncludingNegative(_ records: [TransactionRecord], in range: DateRange, currencyCode: String) -> [(UUID?, Int64)] {
        var totals: [UUID?: Int64] = [:]
        for r in records where r.transactionType == .expense && r.currencyCode == currencyCode && range.contains(r.reportingDate(in: calendar)) {
            totals[r.categoryId, default: 0] += r.isRefund ? -r.amountMinorUnits : r.amountMinorUnits
        }
        return totals.map { ($0.key, $0.value) }
    }
}
