import Foundation

/// Guards against the most common double-count: a card purchase is recorded as an expense,
/// and the later card bill payment is ALSO recorded as an expense.
///
/// Correct model: purchases on the card are expenses (counted once, when made). Paying the
/// card is a *transfer* from a bank account to the card, which never counts as spending.
enum CreditCardRepaymentDetector {
    static let phrases = [
        "credit card payment", "card payment", "cc payment", "payment thank you", "payment - thank you",
        "autopay", "auto pay", "auto-pay", "statement balance", "card bill", "payment to card",
        "minimum payment", "epayment", "e-payment",
    ]

    /// True if the text reads like a credit-card bill payment.
    static func textLooksLikeRepayment(title: String?, merchant: String?) -> Bool {
        let haystack = [title, merchant].compactMap { $0?.lowercased() }.joined(separator: " ")
        return phrases.contains { haystack.contains($0) }
    }

    /// Whether the editor should warn that an expense is probably a card repayment.
    /// Never blocks saving and never changes data on its own; the user decides.
    static func shouldWarn(type: TransactionType, title: String?, merchant: String?, categoryName: String?) -> Bool {
        guard type == .expense else { return false }
        if let c = categoryName?.lowercased(), c.contains("credit card") { return true }
        return textLooksLikeRepayment(title: title, merchant: merchant)
    }

    /// True for a transfer into a credit card, i.e. a recognized repayment.
    static func isRepaymentTransfer(type: TransactionType, destinationType: PaymentMethodType?) -> Bool {
        type == .transfer && destinationType == .creditCard
    }
}
