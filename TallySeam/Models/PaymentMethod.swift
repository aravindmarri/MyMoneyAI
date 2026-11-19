import Foundation
import SwiftData

enum PaymentMethodType: String, Codable, CaseIterable, Identifiable, Sendable {
    case cash, debitCard, creditCard, bankTransfer, applePay, other
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cash: "Cash"
        case .debitCard: "Debit Card"
        case .creditCard: "Credit Card"
        case .bankTransfer: "Bank Transfer"
        case .applePay: "Apple Pay"
        case .other: "Other"
        }
    }
    var symbol: String {
        switch self {
        case .cash: "banknote.fill"
        case .debitCard, .creditCard: "creditcard.fill"
        case .bankTransfer: "building.columns.fill"
        case .applePay: "apple.logo"
        case .other: "wallet.pass.fill"
        }
    }
}

/// Never stores full card numbers, security codes or credentials — only an optional last four.
/// Apple Pay is a payment *channel*; `underlyingPaymentMethodId` optionally references the card behind it.
@Model
final class PaymentMethod {
    @Attribute(.unique) var id: UUID
    var name: String
    var typeRaw: String
    var accountNickname: String?
    var lastFourDigits: String?
    var isActive: Bool
    var createdAt: Date
    var underlyingPaymentMethodId: UUID?

    init(id: UUID = UUID(), name: String, type: PaymentMethodType, accountNickname: String? = nil,
         lastFourDigits: String? = nil, isActive: Bool = true, createdAt: Date = .now, underlyingPaymentMethodId: UUID? = nil) {
        self.id = id; self.name = name; self.typeRaw = type.rawValue; self.accountNickname = accountNickname
        self.lastFourDigits = PaymentMethod.sanitizedLastFour(lastFourDigits); self.isActive = isActive
        self.createdAt = createdAt; self.underlyingPaymentMethodId = underlyingPaymentMethodId
    }

    var type: PaymentMethodType {
        get { PaymentMethodType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }

    /// Exactly four ASCII digits or nil. Longer input is rejected, never truncated,
    /// so a pasted full card number is never persisted.
    static func sanitizedLastFour(_ input: String?) -> String? {
        guard let t = input?.trimmingCharacters(in: .whitespaces), t.count == 4,
              t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return t
    }
}
