import Foundation

/// One account to create during quick setup. Only a name, type and optional last four digits.
struct AccountSetupItem: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var type: PaymentMethodType
    var lastFour = ""
}

/// Ready-made names for common accounts. These are suggestions the user taps, never sample data:
/// nothing is created until the user saves.
enum AccountPresets {
    static let debitBanks = ["Wells Fargo", "Chase", "Bank of America", "Citi", "U.S. Bank", "PNC",
                             "Capital One", "Ally", "Discover", "Truist", "TD Bank"]
    static let creditIssuers = ["Capital One", "American Express", "Chase", "Discover", "Citi",
                                "Bank of America", "Wells Fargo", "Apple Card", "U.S. Bank", "Barclays"]

    /// "Wells Fargo" + debit → "Wells Fargo Debit", "American Express" + credit → "American Express Credit".
    /// Names that already end in "Card", "Debit", "Credit", "Checking" or "Savings" are left as they are.
    static func defaultName(_ institution: String, type: PaymentMethodType) -> String {
        let t = institution.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if ["card", "debit", "credit", "cash", "checking", "savings"].contains(where: { lower.hasSuffix($0) }) { return t }
        switch type {
        case .debitCard: return t + " Debit"
        case .creditCard: return t + " Credit"
        case .bankTransfer: return t + " Checking"
        case .cash, .applePay, .other: return t
        }
    }

    /// Suggested names for the editor's name field, by type.
    static func suggestions(for type: PaymentMethodType) -> [String] {
        switch type {
        case .debitCard, .bankTransfer: debitBanks
        case .creditCard: creditIssuers
        case .cash: ["Cash"]
        case .applePay: ["Apple Pay"]
        case .other: []
        }
    }
}

enum AccountSetupError: Error, Equatable, LocalizedError {
    case invalidLastFour(name: String)
    var errorDescription: String? {
        switch self {
        case .invalidLastFour(let name): "Last 4 digits for \(name) must be exactly 4 numbers, or left empty."
        }
    }
}

enum AccountSetup {
    /// The items that will actually be created: trimmed, without empty names, without duplicates
    /// (case-insensitive) of each other or of existing payment methods. Throws if a last-four is
    /// filled in but isn't exactly four digits, so a pasted card number is never stored.
    static func itemsToCreate(_ items: [AccountSetupItem], existingNames: [String]) throws -> [AccountSetupItem] {
        var seen = Set(existingNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var result: [AccountSetupItem] = []
        for var item in items {
            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            item.lastFour = item.lastFour.trimmingCharacters(in: .whitespaces)
            guard !item.name.isEmpty, seen.insert(item.name.lowercased()).inserted else { continue }
            if !item.lastFour.isEmpty, PaymentMethod.sanitizedLastFour(item.lastFour) == nil {
                throw AccountSetupError.invalidLastFour(name: item.name)
            }
            result.append(item)
        }
        return result
    }
}
