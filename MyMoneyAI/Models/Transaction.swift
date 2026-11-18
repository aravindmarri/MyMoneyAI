import Foundation
import SwiftData

/// How a transaction affects cash flow.
/// - income / expense: counted in cash-flow totals.
/// - transfer: moves money between the user's own accounts (incl. credit-card repayments). Never counted.
/// - adjustment: balance correction. Never counted as income or expense.
enum TransactionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case income, expense, transfer, adjustment
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .income: "Income"
        case .expense: "Expense"
        case .transfer: "Transfer"
        case .adjustment: "Adjustment"
        }
    }
    var symbol: String {
        switch self {
        case .income: "arrow.down.circle.fill"
        case .expense: "arrow.up.circle.fill"
        case .transfer: "arrow.left.arrow.right.circle.fill"
        case .adjustment: "slider.horizontal.3"
        }
    }
    /// Category kind that applies to this type; transfers and adjustments have no category.
    var categoryKind: CategoryKind? {
        switch self {
        case .income: .income
        case .expense: .expense
        case .transfer, .adjustment: nil
        }
    }
}

enum TransactionSource: String, Codable, Sendable {
    case manual, receiptOCR, csvImport

    /// Unknown values (from a newer app version's backup) read as `.manual` instead of failing the import.
    var displayName: String {
        switch self {
        case .manual: "Manual"
        case .receiptOCR: "Receipt"
        case .csvImport: "CSV import"
        }
    }

    init(from decoder: Decoder) throws {
        self = TransactionSource(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .manual
    }
}

/// Immutable value snapshot of a transaction. Calculations operate on this type so financial
/// logic stays independent of SwiftData and is fully unit-testable.
///
/// `amountMinorUnits` is always a non-negative magnitude; direction comes from `transactionType`.
/// `isRefund` reverses the effect inside its bucket (a refunded expense reduces expenses).
struct TransactionRecord: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var transactionDate: Date
    var createdAt: Date
    var updatedAt: Date
    var amountMinorUnits: Int64
    var currencyCode: String
    var merchant: String?
    var title: String
    var notes: String?
    var transactionType: TransactionType
    var categoryId: UUID?
    var paymentMethodId: UUID?
    var receiptId: UUID?
    var recurringBillId: UUID?
    var source: TransactionSource
    var isVerified: Bool
    var transferGroupId: UUID?
    var isRefund: Bool
    /// For transfers: the account receiving the money (e.g. the credit card being repaid).
    /// `paymentMethodId` is the source account.
    var transferDestinationPaymentMethodId: UUID?
    /// The month this transaction counts in, as yyyymm (e.g. 202611), when it differs from the month
    /// of `transactionDate`. Example: a November salary paid on October 29. nil = its own month.
    var countedMonth: Int?

    init(id: UUID = UUID(), transactionDate: Date, createdAt: Date = .now, updatedAt: Date = .now,
         amountMinorUnits: Int64, currencyCode: String = CurrencyMath.defaultCode, merchant: String? = nil,
         title: String, notes: String? = nil, transactionType: TransactionType, categoryId: UUID? = nil,
         paymentMethodId: UUID? = nil, receiptId: UUID? = nil, recurringBillId: UUID? = nil,
         source: TransactionSource = .manual, isVerified: Bool = true, transferGroupId: UUID? = nil,
         isRefund: Bool = false, transferDestinationPaymentMethodId: UUID? = nil, countedMonth: Int? = nil) {
        self.transferDestinationPaymentMethodId = transferDestinationPaymentMethodId
        self.countedMonth = countedMonth
        self.id = id; self.transactionDate = transactionDate; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.amountMinorUnits = amountMinorUnits; self.currencyCode = currencyCode; self.merchant = merchant
        self.title = title; self.notes = notes; self.transactionType = transactionType; self.categoryId = categoryId
        self.paymentMethodId = paymentMethodId; self.receiptId = receiptId; self.recurringBillId = recurringBillId
        self.source = source; self.isVerified = isVerified; self.transferGroupId = transferGroupId; self.isRefund = isRefund
    }
}

/// Persistent transaction. Named `MoneyTransaction` to avoid clashing with `SwiftUI.Transaction`.
@Model
final class MoneyTransaction {
    @Attribute(.unique) var id: UUID
    var transactionDate: Date
    var createdAt: Date
    var updatedAt: Date
    var amountMinorUnits: Int64
    var currencyCode: String
    var merchant: String?
    var title: String
    var notes: String?
    var transactionTypeRaw: String
    var categoryId: UUID?
    var paymentMethodId: UUID?
    var receiptId: UUID?
    var recurringBillId: UUID?
    var sourceRaw: String
    var isVerified: Bool
    var transferGroupId: UUID?
    var isRefund: Bool = false
    var transferDestinationPaymentMethodId: UUID? = nil
    /// Added in schema 2.0.0. See `TransactionRecord.countedMonth`.
    var countedMonth: Int? = nil

    init(record r: TransactionRecord) {
        transferDestinationPaymentMethodId = r.transferDestinationPaymentMethodId
        countedMonth = r.countedMonth
        id = r.id; transactionDate = r.transactionDate; createdAt = r.createdAt; updatedAt = r.updatedAt
        amountMinorUnits = r.amountMinorUnits; currencyCode = r.currencyCode; merchant = r.merchant
        title = r.title; notes = r.notes; transactionTypeRaw = r.transactionType.rawValue
        categoryId = r.categoryId; paymentMethodId = r.paymentMethodId; receiptId = r.receiptId
        recurringBillId = r.recurringBillId; sourceRaw = r.source.rawValue; isVerified = r.isVerified
        transferGroupId = r.transferGroupId; isRefund = r.isRefund
    }

    var transactionType: TransactionType {
        get { TransactionType(rawValue: transactionTypeRaw) ?? .expense }
        set { transactionTypeRaw = newValue.rawValue }
    }
    var source: TransactionSource { TransactionSource(rawValue: sourceRaw) ?? .manual }

    var record: TransactionRecord {
        TransactionRecord(id: id, transactionDate: transactionDate, createdAt: createdAt, updatedAt: updatedAt,
                          amountMinorUnits: amountMinorUnits, currencyCode: currencyCode, merchant: merchant,
                          title: title, notes: notes, transactionType: transactionType, categoryId: categoryId,
                          paymentMethodId: paymentMethodId, receiptId: receiptId, recurringBillId: recurringBillId,
                          source: source, isVerified: isVerified, transferGroupId: transferGroupId, isRefund: isRefund,
                          transferDestinationPaymentMethodId: transferDestinationPaymentMethodId, countedMonth: countedMonth)
    }

    /// Applies editable fields. `id`, `createdAt` and `source` are never changed by an edit.
    func apply(_ r: TransactionRecord) {
        transactionDate = r.transactionDate; amountMinorUnits = r.amountMinorUnits; currencyCode = r.currencyCode
        merchant = r.merchant; title = r.title; notes = r.notes; transactionTypeRaw = r.transactionType.rawValue
        categoryId = r.categoryId; paymentMethodId = r.paymentMethodId; receiptId = r.receiptId
        recurringBillId = r.recurringBillId; isVerified = r.isVerified; transferGroupId = r.transferGroupId
        isRefund = r.isRefund; transferDestinationPaymentMethodId = r.transferDestinationPaymentMethodId
        countedMonth = r.countedMonth
        updatedAt = r.updatedAt
    }
}

/*
 Split transactions (planned for V2): a parent MoneyTransaction holds the total; child
 `TransactionSplit` rows (parentId, amountMinorUnits, categoryId) must sum to the parent.
 Category totals will read children; cash-flow totals still count the parent exactly once.
*/

/// Counting a transaction in a different month (e.g. salary for November that arrives in late October).
enum CountedMonth {
    /// How far from the transaction's own month it may be moved.
    static let allowedOffsets = -1...1

    static func key(year: Int, month: Int) -> Int { year * 100 + month }

    static func key(for date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return key(year: c.year ?? 0, month: c.month ?? 1)
    }

    /// The first day of the month at noon, so time-zone changes never move it to another month.
    static func date(forKey key: Int, calendar: Calendar) -> Date? {
        let year = key / 100, month = key % 100
        guard (1...12).contains(month), (1900...2200).contains(year) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12))
    }

    /// The key for `offset` months after the month of `date`, or nil for offset 0 (its own month).
    static func key(offset: Int, from date: Date, calendar: Calendar) -> Int? {
        guard offset != 0, let moved = calendar.date(byAdding: .month, value: offset, to: date) else { return nil }
        return key(for: moved, calendar: calendar)
    }

    /// Months between the transaction's own month and its counted month (0 when not moved).
    static func offset(of record: TransactionRecord, calendar: Calendar) -> Int {
        guard let k = record.countedMonth, let target = date(forKey: k, calendar: calendar) else { return 0 }
        let own = calendar.monthRange(containing: record.transactionDate).start
        return calendar.dateComponents([.month], from: own, to: calendar.monthRange(containing: target).start).month ?? 0
    }
}

extension TransactionRecord {
    /// The date used for monthly totals, budgets and reports: the transaction date, or the first of
    /// the counted month when the transaction is counted in another month.
    func reportingDate(in calendar: Calendar) -> Date {
        guard let k = countedMonth, k != CountedMonth.key(for: transactionDate, calendar: calendar),
              let d = CountedMonth.date(forKey: k, calendar: calendar) else { return transactionDate }
        return d
    }

    /// True when the transaction counts in a month other than the one it's dated in.
    func isCountedInOtherMonth(calendar: Calendar) -> Bool { reportingDate(in: calendar) != transactionDate }
}
