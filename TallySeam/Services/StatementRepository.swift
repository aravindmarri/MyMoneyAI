import Foundation
import SwiftData

enum StatementImportError: Error, Equatable, LocalizedError {
    case duplicateDocument(importedAt: Date)
    case paymentMethodNotFound
    case notAStatement
    case notFound
    case importHasConfirmedLines(Int)

    var errorDescription: String? {
        switch self {
        case .duplicateDocument(let d):
            "This exact file was already imported on \(d.formatted(date: .abbreviated, time: .shortened)). Open it from Saved Statements instead."
        case .paymentMethodNotFound: "Choose the account this statement belongs to."
        case .notAStatement: "Only bank and credit card statements can be saved for matching. Change the document type first."
        case .notFound: "The statement no longer exists."
        case .importHasConfirmedLines(let n):
            "\(n) line(s) from this statement are already confirmed or added as transactions. Undo those first."
        }
    }
}

/// Saves imported statements and their match suggestions. Never creates, edits or deletes a
/// MoneyTransaction: matching only proposes, and the user confirms in review (Phase C).
@MainActor
final class StatementRepository {
    let context: ModelContext

    init(context: ModelContext) { self.context = context }

    // MARK: Reads

    func fetchStatement(id: UUID) throws -> ImportedStatement? {
        try context.fetch(FetchDescriptor<ImportedStatement>(predicate: #Predicate { $0.id == id })).first
    }

    func duplicate(fingerprint: String) throws -> ImportedStatement? {
        try context.fetch(FetchDescriptor<ImportedStatement>(predicate: #Predicate { $0.fingerprint == fingerprint })).first
    }

    func fetchLines(statementId: UUID) throws -> [StatementTransaction] {
        try context.fetch(FetchDescriptor<StatementTransaction>(predicate: #Predicate { $0.statementId == statementId }))
            .sorted { ($0.sourcePage, $0.sourceLine) < ($1.sourcePage, $1.sourceLine) }
    }

    func fetchMatches(lineIds: Set<UUID>) throws -> [ReconciliationMatch] {
        try context.fetch(FetchDescriptor<ReconciliationMatch>()).filter { lineIds.contains($0.statementTransactionId) }
    }

    func financialAccount(id: UUID) throws -> FinancialAccount? {
        try context.fetch(FetchDescriptor<FinancialAccount>(predicate: #Predicate { $0.id == id })).first
    }

    /// Statement spellings the user confirmed, e.g. "wm supercenter" → "walmart".
    func learnedAliases() throws -> [String: String] {
        Dictionary(try context.fetch(FetchDescriptor<MerchantAlias>()).map { ($0.aliasKey, $0.merchantKey) }, uniquingKeysWith: { a, _ in a })
    }

    /// Remembers that a statement spelling means a merchant. One row per spelling: a repeat
    /// confirmation updates the existing row instead of adding another.
    func learnAlias(statementDescription: String, merchant: String) throws {
        let key = StatementMerchantNormalizer.normalize(statementDescription)
        let target = StatementMerchantNormalizer.normalize(merchant)
        guard !key.isEmpty, !target.isEmpty, key != target else { return }
        if let existing = try context.fetch(FetchDescriptor<MerchantAlias>(predicate: #Predicate { $0.aliasKey == key })).first {
            existing.merchantKey = target
            existing.confirmations += 1
        } else {
            context.insert(MerchantAlias(aliasKey: key, merchantKey: target))
        }
        try context.save()
    }

    /// Transactions already confirmed against some statement line; they can't back another line.
    func alreadyMatchedTransactionIds(excludingStatement: UUID? = nil) throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<StatementTransaction>())
            .filter { $0.status == .matched && $0.statementId != excludingStatement }
            .compactMap(\.matchedTransactionId))
    }

    // MARK: Accounts

    /// The financial account linked to a payment method, created on first use.
    func financialAccount(forPaymentMethod paymentMethodId: UUID, header: StatementHeader, kind: FinancialDocumentKind) throws -> FinancialAccount {
        if let existing = try context.fetch(FetchDescriptor<FinancialAccount>()).first(where: { $0.linkedPaymentMethodId == paymentMethodId }) {
            return existing
        }
        guard let pm = try context.fetch(FetchDescriptor<PaymentMethod>()).first(where: { $0.id == paymentMethodId }) else {
            throw StatementImportError.paymentMethodNotFound
        }
        let type: FinancialAccountType = kind == .creditCardStatement ? .creditCard
            : (header.accountType == .other ? FinancialAccountType(pm.type) : FinancialAccountType(header.accountType))
        let account = FinancialAccount(institutionName: header.institution ?? pm.name, nickname: pm.name, accountType: type,
                                       lastFourDigits: pm.lastFourDigits ?? header.lastFour, currencyCode: header.currencyCode,
                                       linkedPaymentMethodId: pm.id)
        context.insert(account)
        return account
    }

    // MARK: Saving

    /// Saves the statement, its lines and match suggestions in one save. Nothing is kept if any
    /// step fails. Refuses a file that was already imported (same SHA-256).
    @discardableResult
    func saveStatement(_ preview: StatementPreview, filename: String, fingerprint: String, paymentMethodId: UUID?,
                       config: ReconciliationConfig, calendar: Calendar = .current, now: Date = .now) throws -> ImportedStatement {
        guard preview.kind.isStatement else { throw StatementImportError.notAStatement }
        if let dup = try duplicate(fingerprint: fingerprint) { throw StatementImportError.duplicateDocument(importedAt: dup.importedAt) }
        guard let paymentMethodId else { throw StatementImportError.paymentMethodNotFound }
        do {
            let account = try financialAccount(forPaymentMethod: paymentMethodId, header: preview.header, kind: preview.kind)
            let session = ImportSession(startedAt: now)
            session.documentCount = 1
            session.parseIssueCount = preview.parse.issues.count
            session.status = .reviewing
            context.insert(session)

            let h = preview.header
            let statement = ImportedStatement(sessionId: session.id, accountId: account.id, originalFilename: filename,
                                              fingerprint: fingerprint, documentKind: preview.kind, currencyCode: h.currencyCode, importedAt: now)
            statement.institutionName = h.institution; statement.lastFourDigits = h.lastFour
            statement.periodStart = h.periodStart; statement.periodEnd = h.periodEnd
            statement.openingBalance = h.openingBalance; statement.closingBalance = h.closingBalance
            statement.totalDeposits = h.totalDeposits; statement.totalWithdrawals = h.totalWithdrawals
            statement.totalPaymentsAndCredits = h.totalPaymentsAndCredits; statement.totalPurchases = h.totalPurchases
            statement.totalFees = h.totalFees; statement.totalInterest = h.totalInterest
            statement.paymentDueDate = h.paymentDueDate; statement.minimumPayment = h.minimumPayment
            statement.pageCount = preview.pageCount; statement.unreadLineCount = preview.parse.issues.count
            statement.reconciliationStatus = .inProgress
            context.insert(statement)

            let lines = preview.parse.lines.map { StatementTransaction(statementId: statement.id, line: $0, currencyCode: h.currencyCode) }
            lines.forEach { context.insert($0) }
            try suggest(for: lines, account: account, statementId: statement.id, config: config, calendar: calendar)
            try context.save()
            return statement
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Recomputes suggestions for lines still waiting for review, e.g. after changing the date
    /// window. Confirmed, created and skipped lines, and rejected suggestions, are left alone.
    func refreshSuggestions(statementId: UUID, config: ReconciliationConfig, calendar: Calendar = .current) throws {
        guard let statement = try fetchStatement(id: statementId), let account = try financialAccount(id: statement.accountId) else {
            throw StatementImportError.notFound
        }
        do {
            let open = try fetchLines(statementId: statementId).filter { $0.status == .unmatched || $0.status == .suggested }
            for m in try fetchMatches(lineIds: Set(open.map(\.id))) where m.status == .suggested { context.delete(m) }
            try suggest(for: open, account: account, statementId: statementId, config: config, calendar: calendar)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func suggest(for lines: [StatementTransaction], account: FinancialAccount, statementId: UUID,
                         config: ReconciliationConfig, calendar: Calendar) throws {
        guard !lines.isEmpty else { return }
        let rejected = Set(try fetchMatches(lineIds: Set(lines.map(\.id))).filter { $0.status == .rejected }.map { "\($0.statementTransactionId)|\($0.transactionId)" })
        // Only transactions near the statement's dates can match.
        let margin = config.window.rawValue + config.extendedSearchDays + 1
        let dates = lines.flatMap { [$0.transactionDate] + ($0.postingDate.map { [$0] } ?? []) }
        let low = calendar.date(byAdding: .day, value: -margin, to: dates.min() ?? .now) ?? .distantPast
        let high = calendar.date(byAdding: .day, value: margin, to: dates.max() ?? .now) ?? .distantFuture
        let existing = try context.fetch(FetchDescriptor<MoneyTransaction>(predicate: #Predicate { $0.transactionDate >= low && $0.transactionDate <= high }))
            .map(\.record)
        let service = StatementReconciliationService(config: config, calendar: calendar)
        let results = service.reconcile(
            lines: lines.map(\.input), existing: existing,
            account: ReconciliationAccount(paymentMethodId: account.linkedPaymentMethodId, isCreditCard: account.accountType == .creditCard,
                                           displayName: account.nickname),
            alreadyMatched: try blockedTransactionIds(forAccount: account.id, excludingStatement: statementId), learnedAliases: try learnedAliases())
        let byId = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        for r in results {
            guard let line = byId[r.lineId] else { continue }
            let usable = r.candidates.filter { !rejected.contains("\(r.lineId)|\($0.transactionId)") }
            let primary = r.suggestion.flatMap { s in usable.contains(s) ? s : nil }
            if let primary {
                context.insert(ReconciliationMatch(statementTransactionId: line.id, candidate: primary, isAmbiguous: r.isAmbiguous, isPrimary: true))
            }
            for alt in usable.filter({ $0 != primary }).prefix(2) {
                context.insert(ReconciliationMatch(statementTransactionId: line.id, candidate: alt, isAmbiguous: r.isAmbiguous, isPrimary: false))
            }
            line.status = primary == nil ? .unmatched : .suggested
        }
    }

    // MARK: Privacy

    /// Deletes every imported statement with its lines, suggestions and sessions. Transactions are
    /// kept (including ones added from statements); they simply become unverified. Learned merchant
    /// spellings and accounts are kept too.
    @discardableResult
    func deleteAllStatementData() throws -> Int {
        let count = try context.fetchCount(FetchDescriptor<ImportedStatement>())
        do {
            try context.fetch(FetchDescriptor<ReconciliationMatch>()).forEach { context.delete($0) }
            try context.fetch(FetchDescriptor<StatementTransaction>()).forEach { context.delete($0) }
            try context.fetch(FetchDescriptor<ImportedStatement>()).forEach { context.delete($0) }
            try context.fetch(FetchDescriptor<ImportSession>()).forEach { context.delete($0) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return count
    }

    // MARK: Undo

    /// Removes an imported statement with its lines, suggestions and session. Transactions in the
    /// app are never touched. Refused once any line has been confirmed or added (undo those first).
    func deleteImport(statementId: UUID) throws {
        guard let statement = try fetchStatement(id: statementId) else { throw StatementImportError.notFound }
        let lines = try fetchLines(statementId: statementId)
        let committed = lines.filter { $0.status == .matched || $0.status == .created }.count
        guard committed == 0 else { throw StatementImportError.importHasConfirmedLines(committed) }
        do {
            for m in try fetchMatches(lineIds: Set(lines.map(\.id))) { context.delete(m) }
            lines.forEach { context.delete($0) }
            let sessionId = statement.sessionId
            context.delete(statement)
            let others = try context.fetch(FetchDescriptor<ImportedStatement>()).filter { $0.sessionId == sessionId && $0.id != statementId }
            if others.isEmpty, let session = try context.fetch(FetchDescriptor<ImportSession>(predicate: #Predicate { $0.id == sessionId })).first {
                context.delete(session)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

/// The matching window chosen by the user, kept on this device.
enum ReconciliationPreferences {
    static let windowKey = "reconciliation.windowDays"

    static func window(_ defaults: UserDefaults = .standard) -> MatchDateWindow {
        guard defaults.object(forKey: windowKey) != nil else { return .twoDays }
        return MatchDateWindow(rawValue: defaults.integer(forKey: windowKey)) ?? .twoDays
    }

    static func config(_ defaults: UserDefaults = .standard) -> ReconciliationConfig {
        var c = ReconciliationConfig()
        c.window = window(defaults)
        return c
    }
}
