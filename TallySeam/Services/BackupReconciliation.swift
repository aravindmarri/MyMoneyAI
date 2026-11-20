import Foundation
import SwiftData

/// Statement import data in a backup. Optional in the payload, so backups made before statement
/// import still decode, and restoring them simply adds no statements.
struct BackupReconciliationData: Codable, Equatable, Sendable {
    struct Account: Codable, Equatable, Sendable {
        var id: UUID; var institutionName: String; var nickname: String; var accountType: String; var lastFourDigits: String?
        var currencyCode: String; var isActive: Bool; var createdAt: Date; var linkedPaymentMethodId: UUID?
    }
    struct Session: Codable, Equatable, Sendable {
        var id: UUID; var startedAt: Date; var finishedAt: Date?; var status: String; var documentCount: Int; var parseIssueCount: Int
        var confirmedMatchCount: Int; var newTransactionCount: Int; var rejectedSuggestionCount: Int
    }
    struct Statement: Codable, Equatable, Sendable {
        var id: UUID; var sessionId: UUID; var accountId: UUID; var originalFilename: String; var fingerprint: String
        var documentKind: String; var institutionName: String?; var lastFourDigits: String?; var periodStart: Date?; var periodEnd: Date?
        var openingBalance: Int64?; var closingBalance: Int64?; var totalDeposits: Int64?; var totalWithdrawals: Int64?
        var totalPaymentsAndCredits: Int64?; var totalPurchases: Int64?; var totalFees: Int64?; var totalInterest: Int64?
        var paymentDueDate: Date?; var minimumPayment: Int64?; var currencyCode: String; var importedAt: Date; var pageCount: Int
        var unreadLineCount: Int; var reconciliationStatus: String
    }
    struct Line: Codable, Equatable, Sendable {
        var id: UUID; var statementId: UUID; var transactionDate: Date; var postingDate: Date?; var originalDescription: String
        var normalizedMerchant: String; var amountMinorUnits: Int64; var currencyCode: String; var direction: String; var kind: String
        var referenceNumber: String?; var sourcePage: Int; var sourceLine: Int; var confidence: Int; var isPending: Bool
        var wasEditedByUser: Bool; var status: String; var matchedTransactionId: UUID?; var runningBalance: Int64?
    }
    struct Match: Codable, Equatable, Sendable {
        var id: UUID; var statementTransactionId: UUID; var transactionId: UUID; var score: Int; var strength: String
        var reasonsText: String; var dateDifferenceDays: Int; var amountDifferenceMinorUnits: Int64; var merchantSimilarity: Int
        var isAmbiguous: Bool; var isPrimary: Bool; var status: String; var confirmedAt: Date?; var previousAmountMinorUnits: Int64?
    }
    struct Alias: Codable, Equatable, Sendable {
        var id: UUID; var aliasKey: String; var merchantKey: String; var confirmations: Int; var createdAt: Date
    }

    var accounts: [Account] = []
    var sessions: [Session] = []
    var statements: [Statement] = []
    var lines: [Line] = []
    var matches: [Match] = []
    var aliases: [Alias] = []

    var isEmpty: Bool { statements.isEmpty && aliases.isEmpty && accounts.isEmpty }

    /// Rejects data the app could never have produced.
    func validate() throws {
        let statementIds = Set(statements.map(\.id)), lineIds = Set(lines.map(\.id))
        guard Set(accounts.map(\.id)).count == accounts.count, statementIds.count == statements.count, lineIds.count == lines.count,
              Set(matches.map(\.id)).count == matches.count,
              lines.allSatisfy({ $0.amountMinorUnits >= 0 && statementIds.contains($0.statementId) && $0.originalDescription.count <= 10_000 }),
              matches.allSatisfy({ (0...100).contains($0.score) && lineIds.contains($0.statementTransactionId) }),
              statements.allSatisfy({ !$0.fingerprint.isEmpty && $0.originalFilename.count <= 1_000 })
        else { throw BackupError.invalidContents }
    }
}

struct ReconciliationRestoreSummary: Equatable, Sendable {
    var statementsAdded = 0
    var statementsSkipped = 0
    var aliasesAdded = 0
}

extension BackupReconciliationData {
    @MainActor
    static func make(from context: ModelContext) throws -> BackupReconciliationData {
        var d = BackupReconciliationData()
        d.accounts = try context.fetch(FetchDescriptor<FinancialAccount>()).map {
            .init(id: $0.id, institutionName: $0.institutionName, nickname: $0.nickname, accountType: $0.accountTypeRaw,
                  lastFourDigits: $0.lastFourDigits, currencyCode: $0.currencyCode, isActive: $0.isActive, createdAt: $0.createdAt,
                  linkedPaymentMethodId: $0.linkedPaymentMethodId)
        }
        d.sessions = try context.fetch(FetchDescriptor<ImportSession>()).map {
            .init(id: $0.id, startedAt: $0.startedAt, finishedAt: $0.finishedAt, status: $0.statusRaw, documentCount: $0.documentCount,
                  parseIssueCount: $0.parseIssueCount, confirmedMatchCount: $0.confirmedMatchCount,
                  newTransactionCount: $0.newTransactionCount, rejectedSuggestionCount: $0.rejectedSuggestionCount)
        }
        d.statements = try context.fetch(FetchDescriptor<ImportedStatement>()).map {
            .init(id: $0.id, sessionId: $0.sessionId, accountId: $0.accountId, originalFilename: $0.originalFilename, fingerprint: $0.fingerprint,
                  documentKind: $0.documentKindRaw, institutionName: $0.institutionName, lastFourDigits: $0.lastFourDigits,
                  periodStart: $0.periodStart, periodEnd: $0.periodEnd, openingBalance: $0.openingBalance, closingBalance: $0.closingBalance,
                  totalDeposits: $0.totalDeposits, totalWithdrawals: $0.totalWithdrawals, totalPaymentsAndCredits: $0.totalPaymentsAndCredits,
                  totalPurchases: $0.totalPurchases, totalFees: $0.totalFees, totalInterest: $0.totalInterest, paymentDueDate: $0.paymentDueDate,
                  minimumPayment: $0.minimumPayment, currencyCode: $0.currencyCode, importedAt: $0.importedAt, pageCount: $0.pageCount,
                  unreadLineCount: $0.unreadLineCount, reconciliationStatus: $0.reconciliationStatusRaw)
        }
        d.lines = try context.fetch(FetchDescriptor<StatementTransaction>()).map {
            .init(id: $0.id, statementId: $0.statementId, transactionDate: $0.transactionDate, postingDate: $0.postingDate,
                  originalDescription: $0.originalDescription, normalizedMerchant: $0.normalizedMerchant, amountMinorUnits: $0.amountMinorUnits,
                  currencyCode: $0.currencyCode, direction: $0.directionRaw, kind: $0.kindRaw, referenceNumber: $0.referenceNumber,
                  sourcePage: $0.sourcePage, sourceLine: $0.sourceLine, confidence: $0.confidenceRaw, isPending: $0.isPending,
                  wasEditedByUser: $0.wasEditedByUser, status: $0.statusRaw, matchedTransactionId: $0.matchedTransactionId,
                  runningBalance: $0.runningBalance)
        }
        d.matches = try context.fetch(FetchDescriptor<ReconciliationMatch>()).map {
            .init(id: $0.id, statementTransactionId: $0.statementTransactionId, transactionId: $0.transactionId, score: $0.score,
                  strength: $0.strengthRaw, reasonsText: $0.reasonsText, dateDifferenceDays: $0.dateDifferenceDays,
                  amountDifferenceMinorUnits: $0.amountDifferenceMinorUnits, merchantSimilarity: $0.merchantSimilarity,
                  isAmbiguous: $0.isAmbiguous, isPrimary: $0.isPrimary, status: $0.statusRaw, confirmedAt: $0.confirmedAt,
                  previousAmountMinorUnits: $0.previousAmountMinorUnits)
        }
        d.aliases = try context.fetch(FetchDescriptor<MerchantAlias>()).map {
            .init(id: $0.id, aliasKey: $0.aliasKey, merchantKey: $0.merchantKey, confirmations: $0.confirmations, createdAt: $0.createdAt)
        }
        return d
    }

    /// Adds statements that aren't on the device yet (by id and by file fingerprint), with their lines
    /// and matches. Never changes or removes anything already here. Runs inside the caller's save.
    @MainActor
    func restore(into context: ModelContext, knownTransactionIds existingTransactions: Set<UUID>) throws -> ReconciliationRestoreSummary {
        try validate()
        var summary = ReconciliationRestoreSummary()

        // Accounts: reuse one already linked to the same payment method.
        let deviceAccounts = try context.fetch(FetchDescriptor<FinancialAccount>())
        var accountMap: [UUID: UUID] = [:]
        for a in accounts {
            if let same = deviceAccounts.first(where: { $0.id == a.id || ($0.linkedPaymentMethodId != nil && $0.linkedPaymentMethodId == a.linkedPaymentMethodId) }) {
                accountMap[a.id] = same.id
                continue
            }
            let acc = FinancialAccount(id: a.id, institutionName: a.institutionName, nickname: a.nickname,
                                       accountType: FinancialAccountType(rawValue: a.accountType) ?? .other, lastFourDigits: a.lastFourDigits,
                                       currencyCode: a.currencyCode, linkedPaymentMethodId: a.linkedPaymentMethodId, createdAt: a.createdAt)
            acc.isActive = a.isActive
            context.insert(acc)
            accountMap[a.id] = a.id
        }

        let deviceStatements = try context.fetch(FetchDescriptor<ImportedStatement>())
        let knownIds = Set(deviceStatements.map(\.id)), knownPrints = Set(deviceStatements.map(\.fingerprint))
        var added = Set<UUID>()
        for s in statements {
            guard !knownIds.contains(s.id), !knownPrints.contains(s.fingerprint), let accountId = accountMap[s.accountId] else {
                summary.statementsSkipped += 1; continue
            }
            let st = ImportedStatement(id: s.id, sessionId: s.sessionId, accountId: accountId, originalFilename: s.originalFilename,
                                       fingerprint: s.fingerprint, documentKind: FinancialDocumentKind(rawValue: s.documentKind) ?? .unknown,
                                       currencyCode: s.currencyCode, importedAt: s.importedAt)
            st.institutionName = s.institutionName; st.lastFourDigits = PaymentMethod.sanitizedLastFour(s.lastFourDigits)
            st.periodStart = s.periodStart; st.periodEnd = s.periodEnd; st.openingBalance = s.openingBalance; st.closingBalance = s.closingBalance
            st.totalDeposits = s.totalDeposits; st.totalWithdrawals = s.totalWithdrawals; st.totalPaymentsAndCredits = s.totalPaymentsAndCredits
            st.totalPurchases = s.totalPurchases; st.totalFees = s.totalFees; st.totalInterest = s.totalInterest
            st.paymentDueDate = s.paymentDueDate; st.minimumPayment = s.minimumPayment; st.pageCount = s.pageCount
            st.unreadLineCount = s.unreadLineCount; st.reconciliationStatusRaw = s.reconciliationStatus
            context.insert(st)
            added.insert(s.id)
            summary.statementsAdded += 1
        }

        let neededSessions = Set(statements.filter { added.contains($0.id) }.map(\.sessionId))
        let deviceSessions = Set(try context.fetch(FetchDescriptor<ImportSession>()).map(\.id))
        for s in sessions where neededSessions.contains(s.id) && !deviceSessions.contains(s.id) {
            let session = ImportSession(id: s.id, startedAt: s.startedAt)
            session.finishedAt = s.finishedAt; session.statusRaw = s.status; session.documentCount = s.documentCount
            session.parseIssueCount = s.parseIssueCount; session.confirmedMatchCount = s.confirmedMatchCount
            session.newTransactionCount = s.newTransactionCount; session.rejectedSuggestionCount = s.rejectedSuggestionCount
            context.insert(session)
        }

        var addedLines = Set<UUID>()
        for l in lines where added.contains(l.statementId) {
            let line = StatementTransaction(id: l.id, statementId: l.statementId, line: ParsedStatementLine(
                id: l.id, page: l.sourcePage, line: l.sourceLine, transactionDate: l.transactionDate, postingDate: l.postingDate,
                description: l.originalDescription, amountMinorUnits: l.amountMinorUnits,
                direction: StatementDirection(rawValue: l.direction) ?? .moneyOut, runningBalance: l.runningBalance,
                kind: StatementLineKind(rawValue: l.kind) ?? .unknown, isPending: l.isPending,
                confidence: ParseConfidence(rawValue: l.confidence) ?? .medium, note: nil, isEdited: l.wasEditedByUser), currencyCode: l.currencyCode)
            line.normalizedMerchant = l.normalizedMerchant; line.referenceNumber = l.referenceNumber
            // A confirmed link only survives if its transaction is on the device.
            if let t = l.matchedTransactionId, existingTransactions.contains(t) {
                line.matchedTransactionId = t; line.statusRaw = l.status
            } else {
                line.statusRaw = (l.status == "matched" || l.status == "created") ? StatementLineStatus.unmatched.rawValue : l.status
            }
            context.insert(line)
            addedLines.insert(l.id)
        }
        for m in matches where addedLines.contains(m.statementTransactionId) && existingTransactions.contains(m.transactionId) {
            let match = ReconciliationMatch(id: m.id, statementTransactionId: m.statementTransactionId,
                                            candidate: MatchCandidate(transactionId: m.transactionId, score: m.score,
                                                                      strength: MatchStrength(rawValue: m.strength) ?? .weak, reasons: [],
                                                                      dateDifferenceDays: m.dateDifferenceDays,
                                                                      amountDifferenceMinorUnits: m.amountDifferenceMinorUnits,
                                                                      merchantSimilarity: m.merchantSimilarity),
                                            isAmbiguous: m.isAmbiguous, isPrimary: m.isPrimary)
            match.reasonsText = m.reasonsText; match.statusRaw = m.status; match.confirmedAt = m.confirmedAt
            match.previousAmountMinorUnits = m.previousAmountMinorUnits
            context.insert(match)
        }

        let deviceAliases = Set(try context.fetch(FetchDescriptor<MerchantAlias>()).map(\.aliasKey))
        for a in aliases where !deviceAliases.contains(a.aliasKey) {
            let alias = MerchantAlias(id: a.id, aliasKey: a.aliasKey, merchantKey: a.merchantKey, createdAt: a.createdAt)
            alias.confirmations = a.confirmations
            context.insert(alias)
            summary.aliasesAdded += 1
        }
        return summary
    }
}
