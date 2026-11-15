import Foundation

/// Editable form state for adding, editing or duplicating a transaction.
/// Pure value type: validation and record conversion are unit-tested without SwiftData.
struct TransactionDraft: Equatable, Sendable {
    enum ValidationError: Error, Equatable, Sendable, LocalizedError {
        case invalidAmount, zeroAmount, missingTitle, categoryKindMismatch, sameTransferAccounts

        var errorDescription: String? {
            switch self {
            case .invalidAmount: "Enter a valid amount, such as 12.50."
            case .zeroAmount: "The amount must be greater than zero."
            case .missingTitle: "Enter a title or merchant."
            case .categoryKindMismatch: "The selected category doesn't match the transaction type."
            case .sameTransferAccounts: "A transfer needs two different accounts."
            }
        }
    }

    /// nil when creating (including duplicates); set when editing an existing transaction.
    var editingId: UUID?
    var type: TransactionType = .expense
    var amountText = ""
    var currencyCode: String
    var title = ""
    var merchant = ""
    var date: Date
    var categoryId: UUID?
    var paymentMethodId: UUID?
    var transferDestinationPaymentMethodId: UUID?
    var notes = ""
    var isRefund = false

    // Preserved from the original when editing; never exposed for editing.
    var createdAt: Date?
    var source: TransactionSource = .manual
    var receiptId: UUID?
    var recurringBillId: UUID?
    var transferGroupId: UUID?

    init(currencyCode: String, date: Date = .now) {
        self.currencyCode = currencyCode
        self.date = date
    }

    /// Draft for editing an existing record.
    init(editing r: TransactionRecord) {
        editingId = r.id
        type = r.transactionType
        currencyCode = r.currencyCode
        amountText = Self.editableAmount(r.amountMinorUnits, currencyCode: r.currencyCode)
        title = r.title
        merchant = r.merchant ?? ""
        date = r.transactionDate
        categoryId = r.categoryId
        paymentMethodId = r.paymentMethodId
        transferDestinationPaymentMethodId = r.transferDestinationPaymentMethodId
        notes = r.notes ?? ""
        isRefund = r.isRefund
        createdAt = r.createdAt
        source = r.source
        receiptId = r.receiptId
        recurringBillId = r.recurringBillId
        transferGroupId = r.transferGroupId
    }

    /// Draft that copies a record as a NEW transaction dated `date`. The receipt and bill links
    /// are not copied: a receipt belongs to one purchase, and a bill payment must be recorded explicitly.
    static func duplicating(_ r: TransactionRecord, date: Date = .now) -> TransactionDraft {
        var d = TransactionDraft(editing: r)
        d.editingId = nil
        d.createdAt = nil
        d.date = date
        d.source = .manual
        d.receiptId = nil
        d.recurringBillId = nil
        d.transferGroupId = nil
        return d
    }

    /// Plain decimal text using "." (e.g. "1234.50") so it re-parses identically in any locale.
    static func editableAmount(_ minor: Int64, currencyCode: String) -> String {
        let exp = CurrencyMath.exponent(for: currencyCode)
        let value = CurrencyMath.decimal(fromMinorUnits: minor, currencyCode: currencyCode)
        return value.formatted(.number.precision(.fractionLength(exp)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    var amountMinorUnits: Int64? { CurrencyMath.parse(amountText, currencyCode: currencyCode) }

    var resolvedTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? merchant.trimmingCharacters(in: .whitespacesAndNewlines) : t
    }

    /// - Parameter categoryKinds: kind for every existing category id.
    func validationErrors(categoryKinds: [UUID: CategoryKind]) -> [ValidationError] {
        var errors: [ValidationError] = []
        switch amountMinorUnits {
        case nil: errors.append(.invalidAmount)
        case let v? where v <= 0: errors.append(.zeroAmount)
        default: break
        }
        if resolvedTitle.isEmpty { errors.append(.missingTitle) }
        if let c = categoryId, let expected = type.categoryKind, let actual = categoryKinds[c], actual != expected {
            errors.append(.categoryKindMismatch)
        }
        if type == .transfer, let a = paymentMethodId, a == transferDestinationPaymentMethodId {
            errors.append(.sameTransferAccounts)
        }
        return errors
    }

    /// Builds the record to persist. Throws the first validation error.
    /// Fields that don't apply to the type are cleared so stored data is never contradictory.
    func makeRecord(categoryKinds: [UUID: CategoryKind], now: Date = .now) throws -> TransactionRecord {
        if let first = validationErrors(categoryKinds: categoryKinds).first { throw first }
        guard let amount = amountMinorUnits else { throw ValidationError.invalidAmount }
        let m = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let countsAsCashFlow = type == .income || type == .expense
        return TransactionRecord(
            id: editingId ?? UUID(),
            transactionDate: date,
            createdAt: createdAt ?? now,
            updatedAt: now,
            amountMinorUnits: amount,
            currencyCode: currencyCode,
            merchant: m.isEmpty ? nil : m,
            title: resolvedTitle,
            notes: n.isEmpty ? nil : n,
            transactionType: type,
            categoryId: type.categoryKind == nil ? nil : categoryId.flatMap { categoryKinds[$0] == nil ? nil : $0 },
            paymentMethodId: paymentMethodId,
            receiptId: receiptId,
            recurringBillId: recurringBillId,
            source: source,
            isVerified: true,
            transferGroupId: transferGroupId,
            isRefund: countsAsCashFlow ? isRefund : false,
            transferDestinationPaymentMethodId: type == .transfer ? transferDestinationPaymentMethodId : nil
        )
    }
}

/// Search and filter criteria for the transaction list.
struct TransactionFilter: Equatable, Sendable {
    var searchText = ""
    var types: Set<TransactionType> = []
    var categoryId: UUID?
    var paymentMethodId: UUID?
    var startDate: Date?
    var endDate: Date?

    /// True when any criterion other than search is set.
    var hasActiveFilters: Bool {
        !types.isEmpty || categoryId != nil || paymentMethodId != nil || startDate != nil || endDate != nil
    }

    /// Dates are whole days: `startDate` from 00:00 inclusive, `endDate` through the end of that day.
    func matches(_ r: TransactionRecord, calendar: Calendar = .current) -> Bool {
        if !types.isEmpty && !types.contains(r.transactionType) { return false }
        if let c = categoryId, r.categoryId != c { return false }
        if let p = paymentMethodId, r.paymentMethodId != p && r.transferDestinationPaymentMethodId != p { return false }
        if let s = startDate, r.transactionDate < calendar.startOfDay(for: s) { return false }
        if let e = endDate, r.transactionDate >= calendar.dayRange(containing: e).end { return false }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let inTitle = r.title.localizedCaseInsensitiveContains(q)
            let inMerchant = r.merchant?.localizedCaseInsensitiveContains(q) ?? false
            if !inTitle && !inMerchant { return false }
        }
        return true
    }
}
