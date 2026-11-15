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
}

enum TransactionSource: String, Codable, Sendable {
    case manual, receiptOCR
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

    init(id: UUID = UUID(), transactionDate: Date, createdAt: Date = .now, updatedAt: Date = .now,
         amountMinorUnits: Int64, currencyCode: String = CurrencyMath.defaultCode, merchant: String? = nil,
         title: String, notes: String? = nil, transactionType: TransactionType, categoryId: UUID? = nil,
         paymentMethodId: UUID? = nil, receiptId: UUID? = nil, recurringBillId: UUID? = nil,
         source: TransactionSource = .manual, isVerified: Bool = true, transferGroupId: UUID? = nil,
         isRefund: Bool = false) {
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

    init(record r: TransactionRecord) {
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
                          source: source, isVerified: isVerified, transferGroupId: transferGroupId, isRefund: isRefund)
    }
}

/*
 Split transactions (planned for V2): a parent MoneyTransaction holds the total; child
 `TransactionSplit` rows (parentId, amountMinorUnits, categoryId) must sum to the parent.
 Category totals will read children; cash-flow totals still count the parent exactly once.
*/
