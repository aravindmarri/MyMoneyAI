import Foundation
import SwiftData

// Statement import and reconciliation models (schema 3.0.0). None of these is ever summed into
// income or spending: totals come from MoneyTransaction only, so importing a statement can never
// double-count. A statement line counts only after it is confirmed against, or turned into, a
// MoneyTransaction (Phase C).

enum FinancialAccountType: String, CaseIterable, Identifiable, Codable, Sendable {
    case checking, savings, creditCard, cash, other
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .creditCard: "Credit card"
        case .cash: "Cash"
        case .other: "Other"
        }
    }

    init(_ type: StatementAccountType) {
        switch type {
        case .checking: self = .checking
        case .savings: self = .savings
        case .creditCard: self = .creditCard
        case .other: self = .other
        }
    }

    init(_ type: PaymentMethodType) {
        switch type {
        case .creditCard: self = .creditCard
        case .debitCard, .bankTransfer: self = .checking
        case .cash: self = .cash
        case .applePay, .other: self = .other
        }
    }
}

/// An account statements belong to. Linked to the payment method used on transactions, so a
/// statement line can be compared with transactions paid from the same account.
@Model
final class FinancialAccount {
    @Attribute(.unique) var id: UUID
    var institutionName: String
    var nickname: String
    var accountTypeRaw: String
    /// Only ever the last four digits.
    var lastFourDigits: String?
    var currencyCode: String
    var isActive: Bool
    var createdAt: Date
    var linkedPaymentMethodId: UUID?

    init(id: UUID = UUID(), institutionName: String, nickname: String, accountType: FinancialAccountType, lastFourDigits: String?,
         currencyCode: String, linkedPaymentMethodId: UUID?, createdAt: Date = .now) {
        self.id = id; self.institutionName = institutionName; self.nickname = nickname; self.accountTypeRaw = accountType.rawValue
        self.lastFourDigits = PaymentMethod.sanitizedLastFour(lastFourDigits); self.currencyCode = currencyCode
        self.isActive = true; self.createdAt = createdAt; self.linkedPaymentMethodId = linkedPaymentMethodId
    }

    var accountType: FinancialAccountType { FinancialAccountType(rawValue: accountTypeRaw) ?? .other }
}

enum ImportSessionStatus: String, Codable, Sendable { case processing, reviewing, completed, rolledBack }

/// One import of one or more documents, with counts for the review screen and undo.
@Model
final class ImportSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var statusRaw: String
    var documentCount: Int
    var parseIssueCount: Int
    var confirmedMatchCount: Int
    var newTransactionCount: Int
    var rejectedSuggestionCount: Int

    init(id: UUID = UUID(), startedAt: Date = .now) {
        self.id = id; self.startedAt = startedAt; self.statusRaw = ImportSessionStatus.processing.rawValue
        self.documentCount = 0; self.parseIssueCount = 0; self.confirmedMatchCount = 0
        self.newTransactionCount = 0; self.rejectedSuggestionCount = 0
    }

    var status: ImportSessionStatus {
        get { ImportSessionStatus(rawValue: statusRaw) ?? .processing }
        set { statusRaw = newValue.rawValue }
    }
}

enum StatementReconciliationStatus: String, Codable, Sendable { case notStarted, inProgress, reconciled, incomplete }

@Model
final class ImportedStatement {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var accountId: UUID
    var originalFilename: String
    /// Relative path of a retained copy of the document, if the user kept one.
    var localDocumentPath: String?
    /// SHA-256 of the original file.
    var fingerprint: String
    var documentKindRaw: String
    var institutionName: String?
    var lastFourDigits: String?
    var periodStart: Date?
    var periodEnd: Date?
    var openingBalance: Int64?
    var closingBalance: Int64?
    var totalDeposits: Int64?
    var totalWithdrawals: Int64?
    var totalPaymentsAndCredits: Int64?
    var totalPurchases: Int64?
    var totalFees: Int64?
    var totalInterest: Int64?
    var paymentDueDate: Date?
    var minimumPayment: Int64?
    var currencyCode: String
    var importedAt: Date
    var pageCount: Int
    var unreadLineCount: Int
    var processingStatusRaw: String
    var reconciliationStatusRaw: String

    init(id: UUID = UUID(), sessionId: UUID, accountId: UUID, originalFilename: String, fingerprint: String,
         documentKind: FinancialDocumentKind, currencyCode: String, importedAt: Date = .now) {
        self.id = id; self.sessionId = sessionId; self.accountId = accountId; self.originalFilename = originalFilename
        self.fingerprint = fingerprint; self.documentKindRaw = documentKind.rawValue; self.currencyCode = currencyCode
        self.importedAt = importedAt; self.pageCount = 0; self.unreadLineCount = 0
        self.processingStatusRaw = "parsed"; self.reconciliationStatusRaw = StatementReconciliationStatus.notStarted.rawValue
    }

    var documentKind: FinancialDocumentKind { FinancialDocumentKind(rawValue: documentKindRaw) ?? .unknown }
    var reconciliationStatus: StatementReconciliationStatus {
        get { StatementReconciliationStatus(rawValue: reconciliationStatusRaw) ?? .notStarted }
        set { reconciliationStatusRaw = newValue.rawValue }
    }
}

enum StatementLineStatus: String, Codable, Sendable, CaseIterable {
    /// No candidate found.
    case unmatched
    /// One or more suggestions waiting for review.
    case suggested
    /// Confirmed against an existing transaction (Phase C).
    case matched
    /// Turned into a new transaction (Phase C).
    case created
    /// The user chose to leave it out.
    case skipped
}

@Model
final class StatementTransaction {
    @Attribute(.unique) var id: UUID
    var statementId: UUID
    var transactionDate: Date
    var postingDate: Date?
    /// Exactly as printed on the statement.
    var originalDescription: String
    var normalizedMerchant: String
    /// Always positive; `directionRaw` gives the direction.
    var amountMinorUnits: Int64
    var currencyCode: String
    var directionRaw: String
    var kindRaw: String
    var referenceNumber: String?
    var sourcePage: Int
    var sourceLine: Int
    var confidenceRaw: Int
    var isPending: Bool
    var wasEditedByUser: Bool
    /// The account balance printed after this line, if the statement shows one.
    var runningBalance: Int64?
    var statusRaw: String
    var matchedTransactionId: UUID?

    init(id: UUID = UUID(), statementId: UUID, line: ParsedStatementLine, currencyCode: String) {
        self.id = id; self.statementId = statementId; self.transactionDate = line.transactionDate; self.postingDate = line.postingDate
        self.originalDescription = line.description; self.normalizedMerchant = StatementMerchantNormalizer.normalize(line.description)
        self.amountMinorUnits = line.amountMinorUnits; self.currencyCode = currencyCode; self.directionRaw = line.direction.rawValue
        self.kindRaw = line.kind.rawValue; self.sourcePage = line.page; self.sourceLine = line.line
        self.confidenceRaw = line.confidence.rawValue; self.isPending = line.isPending; self.wasEditedByUser = line.isEdited
        self.runningBalance = line.runningBalance
        self.statusRaw = StatementLineStatus.unmatched.rawValue
    }

    var direction: StatementDirection { StatementDirection(rawValue: directionRaw) ?? .moneyOut }
    var kind: StatementLineKind { StatementLineKind(rawValue: kindRaw) ?? .unknown }
    var status: StatementLineStatus {
        get { StatementLineStatus(rawValue: statusRaw) ?? .unmatched }
        set { statusRaw = newValue.rawValue }
    }

    var input: StatementLineInput {
        StatementLineInput(id: id, transactionDate: transactionDate, postingDate: postingDate, description: originalDescription,
                           amountMinorUnits: amountMinorUnits, currencyCode: currencyCode, direction: direction, kind: kind)
    }
}

enum MatchStatus: String, Codable, Sendable { case suggested, confirmed, rejected, unresolved }

@Model
final class ReconciliationMatch {
    @Attribute(.unique) var id: UUID
    var statementTransactionId: UUID
    var transactionId: UUID
    /// 0–100. A weighted, explainable score, not a calibrated probability.
    var score: Int
    var strengthRaw: String
    /// One reason per line, in plain language.
    var reasonsText: String
    var dateDifferenceDays: Int
    var amountDifferenceMinorUnits: Int64
    /// 0–100.
    var merchantSimilarity: Int
    /// Another candidate scored within a few points: the user must choose.
    var isAmbiguous: Bool
    /// The best candidate for its line (others are alternatives).
    var isPrimary: Bool
    var statusRaw: String
    var confirmedAt: Date?
    /// The transaction's amount before the user chose "use the statement amount", so undo can restore it.
    var previousAmountMinorUnits: Int64?

    init(id: UUID = UUID(), statementTransactionId: UUID, candidate: MatchCandidate, isAmbiguous: Bool, isPrimary: Bool) {
        self.id = id; self.statementTransactionId = statementTransactionId; self.transactionId = candidate.transactionId
        self.score = candidate.score; self.strengthRaw = candidate.strength.rawValue; self.reasonsText = candidate.reasons.joined(separator: "\n")
        self.dateDifferenceDays = candidate.dateDifferenceDays; self.amountDifferenceMinorUnits = candidate.amountDifferenceMinorUnits
        self.merchantSimilarity = candidate.merchantSimilarity; self.isAmbiguous = isAmbiguous; self.isPrimary = isPrimary
        self.statusRaw = MatchStatus.suggested.rawValue
    }

    var strength: MatchStrength { MatchStrength(rawValue: strengthRaw) ?? .weak }
    var status: MatchStatus {
        get { MatchStatus(rawValue: statusRaw) ?? .suggested }
        set { statusRaw = newValue.rawValue }
    }
    var reasons: [String] { reasonsText.split(separator: "\n").map(String.init) }
}

/// A statement spelling the user confirmed for a merchant, e.g. "wm supercenter" → "walmart".
/// Learned on the device from confirmed matches (Phase C).
/// One row per `aliasKey` (kept unique by `StatementRepository.learnAlias`).
@Model
final class MerchantAlias {
    @Attribute(.unique) var id: UUID
    var aliasKey: String
    var merchantKey: String
    var confirmations: Int
    var createdAt: Date

    init(id: UUID = UUID(), aliasKey: String, merchantKey: String, createdAt: Date = .now) {
        self.id = id; self.aliasKey = aliasKey; self.merchantKey = merchantKey; self.confirmations = 1; self.createdAt = createdAt
    }
}
