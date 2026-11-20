import Foundation
import SwiftData

enum StatementReviewError: Error, Equatable, LocalizedError {
    case lineNotFound
    case transactionNotFound
    case lineAlreadyResolved
    case transactionAlreadyMatched
    case currencyMismatch
    case directionMismatch
    case notCreatedByImport
    case invalidAmount
    case categoryKindMismatch
    case notATransfer

    var errorDescription: String? {
        switch self {
        case .lineNotFound: "The statement line no longer exists."
        case .transactionNotFound: "The transaction no longer exists."
        case .lineAlreadyResolved: "This line is already confirmed, added or skipped. Undo it first."
        case .transactionAlreadyMatched: "That transaction is already confirmed against another statement line."
        case .currencyMismatch: "The transaction is in a different currency from the statement."
        case .directionMismatch: "Money in can't be matched to money out (or a card payment to a purchase). Choose another transaction."
        case .notCreatedByImport: "Only transactions added from a statement can be removed by undo."
        case .invalidAmount: "The amount must be greater than zero."
        case .categoryKindMismatch: "The category doesn't match the transaction type."
        case .notATransfer: "Only a transfer can be linked to the matching line on the other account's statement."
        }
    }
}

/// What to create for a statement line that isn't in the app yet. Starts as a suggestion the user edits.
struct NewTransactionDecision: Equatable, Sendable {
    var type: TransactionType
    var title: String
    var merchant: String?
    var categoryId: UUID?
    var categorySuggested = false
    var paymentMethodId: UUID?
    var transferDestinationPaymentMethodId: UUID?
    var isRefund = false
    var notes: String?
}

/// A strong, unambiguous, exact-amount suggestion that bulk confirmation would apply.
struct BulkConfirmItem: Identifiable, Equatable {
    var lineId: UUID
    var transactionId: UUID
    var id: UUID { lineId }
}

/// User review of a saved statement (Phase C). Every action is one all-or-nothing save, and every
/// action can be undone. MoneyTransactions are created only from explicit user decisions, an
/// existing transaction's amount changes only when the user asks for it, and dates never change.
extension StatementRepository {

    // MARK: Lookups

    func fetchLine(id: UUID) throws -> StatementTransaction {
        guard let l = try context.fetch(FetchDescriptor<StatementTransaction>(predicate: #Predicate { $0.id == id })).first else {
            throw StatementReviewError.lineNotFound
        }
        return l
    }

    func moneyTransaction(id: UUID) throws -> MoneyTransaction {
        guard let t = try context.fetch(FetchDescriptor<MoneyTransaction>(predicate: #Predicate { $0.id == id })).first else {
            throw StatementReviewError.transactionNotFound
        }
        return t
    }

    private func accountFor(_ line: StatementTransaction) throws -> FinancialAccount {
        guard let s = try fetchStatement(id: line.statementId), let a = try financialAccount(id: s.accountId) else {
            throw StatementImportError.notFound
        }
        return a
    }

    private func reconciliationAccount(_ a: FinancialAccount) -> ReconciliationAccount {
        ReconciliationAccount(paymentMethodId: a.linkedPaymentMethodId, isCreditCard: a.accountType == .creditCard, displayName: a.nickname)
    }

    /// Transactions a line in `accountId` may not use: anything already confirmed against a line in
    /// the same account, and non-transfers confirmed anywhere. A transfer may back one line on each
    /// side (the bank's payment out and the card's payment in) because it is one financial event.
    func blockedTransactionIds(forAccount accountId: UUID, excludingStatement: UUID? = nil, excludingLine: UUID? = nil) throws -> Set<UUID> {
        let statements = Dictionary(try context.fetch(FetchDescriptor<ImportedStatement>()).map { ($0.id, $0.accountId) }, uniquingKeysWith: { a, _ in a })
        let used = try context.fetch(FetchDescriptor<StatementTransaction>())
            .filter { ($0.status == .matched || $0.status == .created) && $0.statementId != excludingStatement && $0.id != excludingLine }
        let ids = Set(used.compactMap(\.matchedTransactionId))
        let transfers = Set(try context.fetch(FetchDescriptor<MoneyTransaction>()).filter { ids.contains($0.id) && $0.transactionType == .transfer }.map(\.id))
        var blocked = Set<UUID>()
        var transferUses: [UUID: Int] = [:]
        for l in used {
            guard let t = l.matchedTransactionId else { continue }
            if !transfers.contains(t) || statements[l.statementId] == accountId { blocked.insert(t) }
            else { transferUses[t, default: 0] += 1 }
        }
        for (t, n) in transferUses where n >= 2 { blocked.insert(t) }
        return blocked
    }

    // MARK: Confirm

    /// Confirms that a statement line is an existing transaction. With `useStatementAmount`, the
    /// transaction's amount is changed to the statement's (the old amount is kept for undo).
    func confirm(lineId: UUID, transactionId: UUID, useStatementAmount: Bool = false, now: Date = .now) throws {
        try transactional { try applyConfirm(lineId: lineId, transactionId: transactionId, useStatementAmount: useStatementAmount, now: now) }
    }

    private func applyConfirm(lineId: UUID, transactionId: UUID, useStatementAmount: Bool, now: Date) throws {
        let line = try fetchLine(id: lineId)
        guard line.status != .matched, line.status != .created, line.status != .skipped else { throw StatementReviewError.lineAlreadyResolved }
        let t = try moneyTransaction(id: transactionId)
        let account = try accountFor(line)
        guard t.currencyCode == line.currencyCode else { throw StatementReviewError.currencyMismatch }
        let service = StatementReconciliationService()
        guard service.directionCompatibility(line: line.input, transaction: t.record, account: reconciliationAccount(account)) != nil else {
            throw StatementReviewError.directionMismatch
        }
        guard !(try blockedTransactionIds(forAccount: account.id, excludingLine: line.id)).contains(transactionId) else {
            throw StatementReviewError.transactionAlreadyMatched
        }

        let matches = try fetchMatches(lineIds: [line.id])
        let match: ReconciliationMatch
        if let existing = matches.first(where: { $0.transactionId == transactionId }) {
            match = existing
        } else {
            let c = service.candidate(line: line.input, transaction: t.record, account: reconciliationAccount(account))
                ?? MatchCandidate(transactionId: transactionId, score: 0, strength: .weak, reasons: ["Chosen by you"],
                                  dateDifferenceDays: service.calendarDays(from: t.transactionDate, to: line.transactionDate),
                                  amountDifferenceMinorUnits: line.amountMinorUnits - t.amountMinorUnits, merchantSimilarity: 0)
            match = ReconciliationMatch(statementTransactionId: line.id, candidate: c, isAmbiguous: false, isPrimary: true)
            context.insert(match)
        }
        for other in matches where other.id != match.id && other.status == .suggested { other.status = .unresolved }
        match.status = .confirmed
        match.confirmedAt = now
        if useStatementAmount, t.amountMinorUnits != line.amountMinorUnits {
            match.previousAmountMinorUnits = t.amountMinorUnits
            t.amountMinorUnits = line.amountMinorUnits
            t.updatedAt = now
        }
        line.status = .matched
        line.matchedTransactionId = transactionId

        // The same purchase can't also be suggested for another line in this account.
        if t.transactionType != .transfer {
            let siblings = try fetchLines(statementId: line.statementId).filter { $0.id != line.id && $0.status == .suggested }
            for m in try fetchMatches(lineIds: Set(siblings.map(\.id))) where m.transactionId == transactionId && m.status == .suggested {
                m.status = .unresolved
            }
            for s in siblings {
                let open = try fetchMatches(lineIds: [s.id]).contains { $0.status == .suggested }
                if !open { s.status = .unmatched }
            }
        }
        // Remember the statement spelling for this merchant.
        let merchant = t.merchant ?? t.title
        if t.transactionType != .transfer, StatementMerchantNormalizer.similarity(line.normalizedMerchant, StatementMerchantNormalizer.normalize(merchant)) < 1 {
            try recordAlias(statementDescription: line.originalDescription, merchant: merchant)
        }
        if let s = try session(for: line) { s.confirmedMatchCount += 1 }
        try updateStatus(statementId: line.statementId)
    }

    // MARK: Reject

    /// Rejects one suggestion. The next best candidate, if any, becomes the suggestion.
    func reject(matchId: UUID) throws {
        try transactional {
            guard let m = try context.fetch(FetchDescriptor<ReconciliationMatch>(predicate: #Predicate { $0.id == matchId })).first else { return }
            let line = try fetchLine(id: m.statementTransactionId)
            guard m.status == .suggested else { return }
            m.status = .rejected
            if m.isPrimary {
                m.isPrimary = false
                let next = try fetchMatches(lineIds: [line.id]).filter { $0.status == .suggested }.max { $0.score < $1.score }
                next?.isPrimary = true
            }
            let stillOpen = try fetchMatches(lineIds: [line.id]).contains { $0.status == .suggested }
            if !stillOpen { line.status = .unmatched }
            if let s = try session(for: line) { s.rejectedSuggestionCount += 1 }
        }
    }

    // MARK: Create

    /// A starting point for adding a statement line as a new transaction.
    func proposedNewTransaction(lineId: UUID, categories: [CategoryOption], paymentMethods: [PaymentMethod],
                                suggester: any CategorySuggesting) throws -> NewTransactionDecision {
        let line = try fetchLine(id: lineId)
        let account = try accountFor(line)
        let merchant = Self.displayName(forMerchantKey: line.normalizedMerchant)
        let accountPM = account.linkedPaymentMethodId
        var d: NewTransactionDecision
        switch line.kind {
        case .cardPayment, .transfer:
            if line.direction == .moneyOut {
                // Bank → card (or another own account). Guess the card from the description.
                d = NewTransactionDecision(type: .transfer, title: line.kind == .cardPayment ? "Credit card payment" : "Transfer", merchant: nil,
                                           paymentMethodId: accountPM, transferDestinationPaymentMethodId: Self.guessAccount(in: line.originalDescription, from: paymentMethods, excluding: accountPM))
            } else {
                d = NewTransactionDecision(type: .transfer, title: line.kind == .cardPayment ? "Credit card payment" : "Transfer", merchant: nil,
                                           paymentMethodId: Self.guessAccount(in: line.originalDescription, from: paymentMethods.filter { $0.type != .creditCard }, excluding: accountPM),
                                           transferDestinationPaymentMethodId: accountPM)
            }
        case .cashWithdrawal:
            d = NewTransactionDecision(type: .transfer, title: "Cash withdrawal", merchant: nil, paymentMethodId: accountPM,
                                       transferDestinationPaymentMethodId: paymentMethods.first { $0.type == .cash && $0.isActive }?.id)
        case .refund:
            d = NewTransactionDecision(type: .expense, title: merchant, merchant: merchant, paymentMethodId: accountPM, isRefund: true)
        case .deposit:
            d = NewTransactionDecision(type: .income, title: merchant, merchant: merchant, paymentMethodId: accountPM)
        case .purchase, .withdrawal, .fee, .interest, .unknown:
            d = line.direction == .moneyIn
                ? NewTransactionDecision(type: .income, title: merchant, merchant: merchant, paymentMethodId: accountPM)
                : NewTransactionDecision(type: .expense, title: merchant, merchant: merchant, paymentMethodId: accountPM)
            if line.kind == .interest { d.title = "Interest charge" }
            if line.kind == .fee { d.title = "Bank fee" }
        }
        d.notes = "From statement: \(line.originalDescription)"
        if let kind = d.type.categoryKind {
            let history = try context.fetch(FetchDescriptor<MoneyTransaction>()).map(\.record)
            if line.kind == .interest || line.kind == .fee {
                d.categoryId = categories.first { $0.kind == .expense && $0.name.caseInsensitiveCompare("Other") == .orderedSame }?.id
            } else if let s = suggester.suggest(merchant: merchant, receiptText: line.originalDescription, kind: kind, categories: categories, history: history) {
                d.categoryId = s.categoryId
                d.categorySuggested = true
            }
        }
        return d
    }

    /// Adds a statement line as a new transaction, dated with the statement's transaction date
    /// (never the posting date).
    @discardableResult
    func createTransaction(lineId: UUID, decision d: NewTransactionDecision, now: Date = .now) throws -> UUID {
        var createdId = UUID()
        try transactional {
            let line = try fetchLine(id: lineId)
            guard line.status != .matched, line.status != .created, line.status != .skipped else { throw StatementReviewError.lineAlreadyResolved }
            guard line.amountMinorUnits > 0 else { throw StatementReviewError.invalidAmount }
            if let c = d.categoryId, let kind = d.type.categoryKind,
               let cat = try context.fetch(FetchDescriptor<SpendingCategory>(predicate: #Predicate { $0.id == c })).first, cat.kind != kind {
                throw StatementReviewError.categoryKindMismatch
            }
            let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = TransactionRecord(
                transactionDate: line.transactionDate, createdAt: now, updatedAt: now, amountMinorUnits: line.amountMinorUnits,
                currencyCode: line.currencyCode, merchant: d.merchant?.isEmpty == false ? d.merchant : nil,
                title: title.isEmpty ? line.originalDescription : title, notes: d.notes, transactionType: d.type,
                categoryId: d.type.categoryKind == nil ? nil : d.categoryId, paymentMethodId: d.paymentMethodId,
                source: .statementImport, isVerified: true, isRefund: (d.type == .income || d.type == .expense) && d.isRefund,
                transferDestinationPaymentMethodId: d.type == .transfer ? d.transferDestinationPaymentMethodId : nil)
            context.insert(MoneyTransaction(record: record))
            createdId = record.id
            for m in try fetchMatches(lineIds: [line.id]) where m.status == .suggested { m.status = .unresolved }
            let match = ReconciliationMatch(statementTransactionId: line.id,
                                            candidate: MatchCandidate(transactionId: record.id, score: 100, strength: .strong,
                                                                      reasons: ["Added from the statement"], dateDifferenceDays: 0,
                                                                      amountDifferenceMinorUnits: 0, merchantSimilarity: 100),
                                            isAmbiguous: false, isPrimary: true)
            match.status = .confirmed
            match.confirmedAt = now
            context.insert(match)
            line.status = .created
            line.matchedTransactionId = record.id
            if let s = try session(for: line) { s.newTransactionCount += 1 }
            try updateStatus(statementId: line.statementId)
        }
        return createdId
    }

    // MARK: Skip and undo

    /// Leaves a line out (outside what the user tracks, or a duplicate of a line already reconciled).
    func skip(lineId: UUID) throws {
        try transactional {
            let line = try fetchLine(id: lineId)
            guard line.status == .unmatched || line.status == .suggested else { throw StatementReviewError.lineAlreadyResolved }
            for m in try fetchMatches(lineIds: [line.id]) where m.status == .suggested { m.status = .unresolved }
            line.status = .skipped
            try updateStatus(statementId: line.statementId)
        }
    }

    /// Undoes a confirm, create or skip. A transaction added from the statement is deleted; an
    /// amount changed on confirm is restored. Other transactions are never touched.
    func undo(lineId: UUID) throws {
        try transactional { try applyUndo(lineId: lineId) }
    }

    private func applyUndo(lineId: UUID) throws {
        let line = try fetchLine(id: lineId)
        let matches = try fetchMatches(lineIds: [line.id])
        var deleted = Set<UUID>()
        switch line.status {
        case .matched:
            if let m = matches.first(where: { $0.status == .confirmed }) {
                if let old = m.previousAmountMinorUnits, let t = try? moneyTransaction(id: m.transactionId) { t.amountMinorUnits = old }
                m.previousAmountMinorUnits = nil
                m.status = .suggested
                m.confirmedAt = nil
                m.isPrimary = true
            }
            if let s = try session(for: line) { s.confirmedMatchCount = max(0, s.confirmedMatchCount - 1) }
        case .created:
            guard let id = line.matchedTransactionId else { break }
            if let t = try? moneyTransaction(id: id) {
                guard t.source == .statementImport else { throw StatementReviewError.notCreatedByImport }
                // A transfer added here may also back the other account's line: release that too.
                for other in try context.fetch(FetchDescriptor<StatementTransaction>()) where other.id != line.id && other.matchedTransactionId == id {
                    other.matchedTransactionId = nil
                    for m in try fetchMatches(lineIds: [other.id]) where m.transactionId == id { context.delete(m) }
                    let open = try fetchMatches(lineIds: [other.id]).filter { $0.transactionId != id && $0.status == .suggested }
                    other.status = open.isEmpty ? .unmatched : .suggested
                    try updateStatus(statementId: other.statementId)
                }
                context.delete(t)
            }
            for m in matches where m.transactionId == id { deleted.insert(m.id); context.delete(m) }
            if let s = try session(for: line) { s.newTransactionCount = max(0, s.newTransactionCount - 1) }
        case .skipped, .unmatched, .suggested:
            break
        }
        for m in matches where !deleted.contains(m.id) && m.status == .unresolved { m.status = .suggested }
        line.matchedTransactionId = nil
        let remaining = matches.filter { !deleted.contains($0.id) && $0.status == .suggested }
        if !remaining.isEmpty, !remaining.contains(where: \.isPrimary) { remaining.max { $0.score < $1.score }?.isPrimary = true }
        line.status = remaining.isEmpty ? .unmatched : .suggested
        try updateStatus(statementId: line.statementId)
    }

    // MARK: Bulk

    /// Strong, unambiguous suggestions with exactly the same amount, each using a different transaction.
    func bulkConfirmCandidates(statementId: UUID) throws -> [BulkConfirmItem] {
        let lines = try fetchLines(statementId: statementId).filter { $0.status == .suggested }
        let matches = try fetchMatches(lineIds: Set(lines.map(\.id)))
        var used = Set<UUID>()
        var items: [BulkConfirmItem] = []
        for line in lines {
            guard let m = matches.first(where: { $0.statementTransactionId == line.id && $0.isPrimary && $0.status == .suggested }),
                  m.strength == .strong, !m.isAmbiguous, m.amountDifferenceMinorUnits == 0, used.insert(m.transactionId).inserted else { continue }
            items.append(BulkConfirmItem(lineId: line.id, transactionId: m.transactionId))
        }
        return items
    }

    /// Confirms the given items together. If any fails, none is saved.
    @discardableResult
    func bulkConfirm(_ items: [BulkConfirmItem], now: Date = .now) throws -> Int {
        try transactional {
            for item in items { try applyConfirm(lineId: item.lineId, transactionId: item.transactionId, useStatementAmount: false, now: now) }
        }
        return items.count
    }

    // MARK: Transfers across accounts

    /// Lines on other accounts' statements that look like the other side of this transfer (a bank's
    /// card payment out ↔ the card's payment credit in): opposite direction, same amount and
    /// currency, within 5 days, not yet resolved.
    func transferCounterparts(lineId: UUID, calendar: Calendar = .current) throws -> [StatementTransaction] {
        let line = try fetchLine(id: lineId)
        guard [.cardPayment, .transfer].contains(line.kind) else { return [] }
        let account = try accountFor(line).id
        let statements = Dictionary(try context.fetch(FetchDescriptor<ImportedStatement>()).map { ($0.id, $0.accountId) }, uniquingKeysWith: { a, _ in a })
        let amount = line.amountMinorUnits
        let candidates = try context.fetch(FetchDescriptor<StatementTransaction>(predicate: #Predicate { $0.amountMinorUnits == amount }))
        let service = StatementReconciliationService(calendar: calendar)
        return candidates.filter {
            $0.id != line.id && statements[$0.statementId] != account && statements[$0.statementId] != nil
                && $0.direction != line.direction && $0.currencyCode == line.currencyCode
                && ($0.status == .unmatched || $0.status == .suggested)
                && abs(service.calendarDays(from: line.transactionDate, to: $0.transactionDate)) <= 5
        }
        .sorted { abs(service.calendarDays(from: line.transactionDate, to: $0.transactionDate)) < abs(service.calendarDays(from: line.transactionDate, to: $1.transactionDate)) }
    }

    /// Links the other account's line to the same transfer, so one transfer is backed by both
    /// statements and counted once (as a transfer, never as spending).
    func pairTransfer(lineId: UUID, counterpartId: UUID, now: Date = .now) throws {
        try transactional {
            let line = try fetchLine(id: lineId)
            guard let tid = line.matchedTransactionId, line.status == .matched || line.status == .created else { throw StatementReviewError.lineAlreadyResolved }
            let t = try moneyTransaction(id: tid)
            guard t.transactionType == .transfer else { throw StatementReviewError.notATransfer }
            let other = try fetchLine(id: counterpartId)
            let otherAccount = try accountFor(other)
            // Fill in the side of the transfer the other statement proves, if it was unknown.
            if other.direction == .moneyIn, t.transferDestinationPaymentMethodId == nil { t.transferDestinationPaymentMethodId = otherAccount.linkedPaymentMethodId }
            if other.direction == .moneyOut, t.paymentMethodId == nil { t.paymentMethodId = otherAccount.linkedPaymentMethodId }
            try applyConfirm(lineId: other.id, transactionId: tid, useStatementAmount: false, now: now)
        }
    }

    // MARK: Duplicates and gaps

    /// Lines that repeat a line already reconciled (or skipped) on another statement of the same
    /// account, as happens when statement periods overlap. Keyed by this statement's line id.
    func overlappingDuplicates(statementId: UUID, calendar: Calendar = .current) throws -> [UUID: StatementTransaction] {
        guard let statement = try fetchStatement(id: statementId) else { return [:] }
        let accountId = statement.accountId
        let otherStatements = Set(try context.fetch(FetchDescriptor<ImportedStatement>()).filter { $0.accountId == accountId && $0.id != statementId }.map(\.id))
        guard !otherStatements.isEmpty else { return [:] }
        let others = try context.fetch(FetchDescriptor<StatementTransaction>())
            .filter { otherStatements.contains($0.statementId) && ($0.status == .matched || $0.status == .created || $0.status == .skipped) }
        var pool = Dictionary(grouping: others) { Self.lineKey($0, calendar) }
        var result: [UUID: StatementTransaction] = [:]
        for l in try fetchLines(statementId: statementId) where l.status == .unmatched || l.status == .suggested {
            let k = Self.lineKey(l, calendar)
            if var list = pool[k], !list.isEmpty { result[l.id] = list.removeFirst(); pool[k] = list }
        }
        return result
    }

    /// Groups of identical lines (same day, amount, direction and merchant) within one statement.
    /// They're kept as separate purchases unless the user skips one.
    func identicalLineGroups(statementId: UUID, calendar: Calendar = .current) throws -> [[UUID]] {
        Dictionary(grouping: try fetchLines(statementId: statementId)) { Self.lineKey($0, calendar) }
            .values.filter { $0.count > 1 }.map { $0.map(\.id) }.sorted { $0[0].uuidString < $1[0].uuidString }
    }

    /// Transactions recorded on this statement's account during its period that no line accounts
    /// for. The last 3 days of the period are left out, because those may post on the next statement.
    func appTransactionsMissingFromStatement(statementId: UUID, calendar: Calendar = .current) throws -> [TransactionRecord] {
        guard let s = try fetchStatement(id: statementId), let start = s.periodStart, let end = s.periodEnd,
              let account = try financialAccount(id: s.accountId), let pm = account.linkedPaymentMethodId else { return [] }
        let from = calendar.startOfDay(for: start)
        guard let until = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: end)) else { return [] }
        let accounted = Set(try context.fetch(FetchDescriptor<StatementTransaction>()).compactMap(\.matchedTransactionId))
        return try context.fetch(FetchDescriptor<MoneyTransaction>(predicate: #Predicate { $0.transactionDate >= from && $0.transactionDate < until }))
            .map(\.record)
            .filter { ($0.paymentMethodId == pm || $0.transferDestinationPaymentMethodId == pm) && $0.currencyCode == s.currencyCode
                && $0.transactionType != .adjustment && !accounted.contains($0.id) }
            .sorted { $0.transactionDate < $1.transactionDate }
    }

    // MARK: Undo a whole import

    /// Undoes everything this import did (transactions it added are deleted, confirmed matches are
    /// released, changed amounts restored) and removes the import. Nothing else is touched.
    func rollbackImport(statementId: UUID) throws {
        try transactional {
            for l in try fetchLines(statementId: statementId) where l.status != .unmatched && l.status != .suggested {
                try applyUndo(lineId: l.id)
            }
        }
        try deleteImport(statementId: statementId)
    }

    // MARK: Balance

    func balanceInput(_ s: ImportedStatement, lines: [StatementTransaction]) -> StatementBalanceInput {
        StatementBalanceInput(
            isCreditCard: s.documentKind == .creditCardStatement, currencyCode: s.currencyCode,
            openingBalance: s.openingBalance, closingBalance: s.closingBalance, totalDeposits: s.totalDeposits,
            totalWithdrawals: s.totalWithdrawals, totalPaymentsAndCredits: s.totalPaymentsAndCredits, totalPurchases: s.totalPurchases,
            totalFees: s.totalFees, totalInterest: s.totalInterest,
            lines: lines.map { StatementBalanceInput.Line(amountMinorUnits: $0.amountMinorUnits, direction: $0.direction,
                                                          runningBalance: $0.runningBalance, page: $0.sourcePage, line: $0.sourceLine,
                                                          isPending: $0.isPending) },
            unreadLineCount: s.unreadLineCount)
    }

    func balanceReport(statementId: UUID) throws -> StatementBalanceReport {
        guard let s = try fetchStatement(id: statementId) else { throw StatementImportError.notFound }
        return StatementBalanceValidator.validate(balanceInput(s, lines: try fetchLines(statementId: statementId)))
    }

    /// Transactions backed by a confirmed or created statement line.
    func verifiedTransactionIds() throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<StatementTransaction>())
            .filter { $0.status == .matched || $0.status == .created }.compactMap(\.matchedTransactionId))
    }

    // MARK: Helpers

    private static func lineKey(_ l: StatementTransaction, _ calendar: Calendar) -> String {
        "\(calendar.startOfDay(for: l.transactionDate).timeIntervalSince1970)|\(l.amountMinorUnits)|\(l.directionRaw)|\(l.normalizedMerchant)"
    }

    /// "blue bottle" → "Blue Bottle".
    nonisolated static func displayName(forMerchantKey key: String) -> String {
        key.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// A payment method whose name appears in the description (e.g. "CHASE CREDIT CRD AUTOPAY" → Chase Credit).
    static func guessAccount(in description: String, from methods: [PaymentMethod], excluding: UUID?) -> UUID? {
        let d = MerchantName.normalize(description)
        return methods.filter { $0.id != excluding && $0.isActive }.first { m in
            let words = MerchantName.normalize(m.name).split(separator: " ").filter { !["debit", "credit", "card", "checking", "savings"].contains($0) }
            guard let first = words.first else { return false }
            return MerchantName.containsPhrase(d, words.prefix(2).joined(separator: " ")) || MerchantName.containsPhrase(d, String(first))
                || (first == "american" && MerchantName.containsPhrase(d, "amex"))
        }?.id
    }

    private func recordAlias(statementDescription: String, merchant: String) throws {
        let key = StatementMerchantNormalizer.normalize(statementDescription)
        let target = StatementMerchantNormalizer.normalize(merchant)
        guard !key.isEmpty, !target.isEmpty, key != target else { return }
        if let existing = try context.fetch(FetchDescriptor<MerchantAlias>(predicate: #Predicate { $0.aliasKey == key })).first {
            existing.merchantKey = target
            existing.confirmations += 1
        } else {
            context.insert(MerchantAlias(aliasKey: key, merchantKey: target))
        }
    }

    private func session(for line: StatementTransaction) throws -> ImportSession? {
        guard let s = try fetchStatement(id: line.statementId) else { return nil }
        let sid = s.sessionId
        return try context.fetch(FetchDescriptor<ImportSession>(predicate: #Predicate { $0.id == sid })).first
    }

    /// Reviewed when every line is confirmed, added or skipped. A statement with unread lines is
    /// never called reconciled (Phase D adds balance checks).
    private func updateStatus(statementId: UUID) throws {
        guard let s = try fetchStatement(id: statementId) else { return }
        let lines = try fetchLines(statementId: statementId)
        let open = lines.contains { $0.status == .unmatched || $0.status == .suggested }
        // Reconciled only when every line is reviewed AND the balance is proven; otherwise incomplete.
        let verdict = StatementBalanceValidator.validate(balanceInput(s, lines: lines)).verdict
        s.reconciliationStatus = open ? .inProgress : (verdict == .verified ? .reconciled : .incomplete)
        if let session = try context.fetch(FetchDescriptor<ImportSession>()).first(where: { $0.id == s.sessionId }) {
            session.status = open ? .reviewing : .completed
            session.finishedAt = open ? nil : .now
        }
    }

    private func transactional(_ body: () throws -> Void) throws {
        do {
            try body()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
