import Foundation
import SwiftData
import XCTest
@testable import TallySeam

/// Phase C: reviewing a saved statement. In-memory store, synthetic statements, fixed calendar.
@MainActor
final class StatementReviewTests: XCTestCase {
    private var persistence: PersistenceService!
    private var repo: StatementRepository!
    private var chase: PaymentMethod!
    private var wells: PaymentMethod!
    private var context: ModelContext { persistence.context }
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    override func setUp() async throws {
        persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        repo = StatementRepository(context: context)
        chase = PaymentMethod(name: "Chase Credit", type: .creditCard, lastFourDigits: "1111")
        wells = PaymentMethod(name: "Wells Fargo Debit", type: .debitCard, lastFourDigits: "2222")
        context.insert(chase); context.insert(wells)
        try context.save()
    }

    // MARK: Helpers

    private func day(_ m: Int, _ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))! }

    @discardableResult
    private func addTransaction(_ amount: Int64, _ merchant: String, _ date: Date, type: TransactionType = .expense,
                                pm: UUID? = nil, to: UUID? = nil, currency: String = "USD") throws -> TransactionRecord {
        let r = TransactionRecord(transactionDate: date, amountMinorUnits: amount, currencyCode: currency, merchant: merchant, title: merchant,
                                  transactionType: type, paymentMethodId: pm, transferDestinationPaymentMethodId: to)
        context.insert(MoneyTransaction(record: r))
        try context.save()
        return r
    }

    private func preview(_ lines: [String]) -> StatementPreview {
        StatementImportService.preview(text: DocumentText(pages: [DocumentPage(index: 0, lines: lines, source: .plainText)]),
                                       format: .text, defaultCurrency: "USD", calendar: cal, now: day(8, 1))
    }

    /// A July card statement for the Chase card with the given purchase and payment lines.
    @discardableResult
    private func saveCard(purchases: [String], payments: [String] = [], fingerprint: String = UUID().uuidString) throws -> ImportedStatement {
        let text = ["Chase", "Card ending in 1111", "Opening/Closing Date 07/01/2026 - 07/31/2026", "New Balance $0.00", "Purchases"]
            + purchases + (payments.isEmpty ? [] : ["Payments and Credits"] + payments)
        let p = preview(text)
        XCTAssertEqual(p.kind, .creditCardStatement)
        return try repo.saveStatement(p, filename: "card.pdf", fingerprint: fingerprint, paymentMethodId: chase.id, config: ReconciliationConfig(), calendar: cal)
    }

    @discardableResult
    private func saveBank(withdrawals: [String], fingerprint: String = UUID().uuidString) throws -> ImportedStatement {
        let text = ["Wells Fargo Everyday Checking", "Statement period 07/01/2026 - 07/31/2026", "Beginning balance $1,000.00",
                    "Ending balance $900.00", "Withdrawals"] + withdrawals
        let p = preview(text)
        XCTAssertEqual(p.kind, .bankStatement)
        return try repo.saveStatement(p, filename: "bank.pdf", fingerprint: fingerprint, paymentMethodId: wells.id, config: ReconciliationConfig(), calendar: cal)
    }

    private func line(_ s: ImportedStatement, _ merchant: String) throws -> StatementTransaction {
        try XCTUnwrap(try repo.fetchLines(statementId: s.id).first { $0.originalDescription.contains(merchant) })
    }

    private var categories: [CategoryOption] {
        (try? context.fetch(FetchDescriptor<SpendingCategory>()).map { CategoryOption(id: $0.id, name: $0.name, kind: $0.kind) }) ?? []
    }

    private func julyTotals() throws -> PeriodSummary {
        FinanceCalculationService(calendar: cal).summary(of: try TransactionRepository(context: context).allRecords(),
                                                         in: cal.monthRange(containing: day(7, 15)), currencyCode: "USD")
    }

    // MARK: Confirm, reject, undo

    func testConfirmLearnsAliasAndUndoRestores() throws {
        let gym = try addTransaction(3_000, "Corner Gym", day(7, 8), pm: chase.id)
        let s = try saveCard(purchases: ["07/08 ACME HOLDINGS 30.00"])
        let l = try line(s, "ACME")
        XCTAssertEqual(l.status, .suggested)
        try repo.confirm(lineId: l.id, transactionId: gym.id)
        XCTAssertEqual(l.status, .matched); XCTAssertEqual(l.matchedTransactionId, gym.id)
        XCTAssertEqual(try repo.fetchMatches(lineIds: [l.id]).first { $0.transactionId == gym.id }?.status, .confirmed)
        XCTAssertEqual(try repo.learnedAliases()["acme holdings"], "corner gym")
        XCTAssertEqual(try repo.fetchStatement(id: s.id)?.reconciliationStatus, .reconciled)

        try repo.undo(lineId: l.id)
        XCTAssertEqual(l.status, .suggested); XCTAssertNil(l.matchedTransactionId)
        XCTAssertEqual(try repo.fetchMatches(lineIds: [l.id]).first { $0.transactionId == gym.id }?.status, .suggested)
        XCTAssertEqual(try repo.fetchStatement(id: s.id)?.reconciliationStatus, .inProgress)
    }

    func testStatementAmountIsUsedOnlyWhenAskedAndUndoRestoresIt() throws {
        let dinner = try addTransaction(5_000, "Joes Diner", day(7, 6), pm: chase.id)
        let s = try saveCard(purchases: ["07/06 JOES DINER 59.00"])
        let l = try line(s, "JOES")
        try repo.confirm(lineId: l.id, transactionId: dinner.id, useStatementAmount: true)
        XCTAssertEqual(try repo.moneyTransaction(id: dinner.id).amountMinorUnits, 5_900)
        XCTAssertEqual(try repo.moneyTransaction(id: dinner.id).transactionDate, day(7, 6), "the date is never changed")
        try repo.undo(lineId: l.id)
        XCTAssertEqual(try repo.moneyTransaction(id: dinner.id).amountMinorUnits, 5_000)

        try repo.confirm(lineId: l.id, transactionId: dinner.id)
        XCTAssertEqual(try repo.moneyTransaction(id: dinner.id).amountMinorUnits, 5_000, "the amount is kept unless the user asks")
    }

    func testRejectPromotesTheNextCandidate() throws {
        try addTransaction(2_000, "Gas Station", day(7, 9), pm: chase.id)
        try addTransaction(2_000, "Gas Station", day(7, 9), pm: chase.id)
        let s = try saveCard(purchases: ["07/09 GAS STATION 20.00"])
        let l = try line(s, "GAS")
        let first = try XCTUnwrap(try repo.fetchMatches(lineIds: [l.id]).first { $0.isPrimary })
        XCTAssertTrue(first.isAmbiguous)
        try repo.reject(matchId: first.id)
        let second = try XCTUnwrap(try repo.fetchMatches(lineIds: [l.id]).first { $0.isPrimary && $0.status == .suggested })
        XCTAssertNotEqual(second.id, first.id)
        try repo.reject(matchId: second.id)
        XCTAssertEqual(l.status, .unmatched)
        // Re-running matching doesn't bring rejected suggestions back.
        try repo.refreshSuggestions(statementId: s.id, config: ReconciliationConfig(), calendar: cal)
        XCTAssertFalse(try repo.fetchMatches(lineIds: [l.id]).contains { $0.status == .suggested })
    }

    func testHardRulesOnConfirm() throws {
        let grocery = try addTransaction(10_000, "Grocery Outlet", day(7, 2), pm: chase.id)
        let euro = try addTransaction(10_000, "Grocery Outlet", day(7, 2), pm: chase.id, currency: "EUR")
        let s = try saveCard(purchases: ["07/02 GROCERY OUTLET 100.00"], payments: ["07/21 AUTOPAY PAYMENT THANK YOU -100.00"])
        let payment = try line(s, "AUTOPAY")
        XCTAssertThrowsError(try repo.confirm(lineId: payment.id, transactionId: grocery.id)) {
            XCTAssertEqual($0 as? StatementReviewError, .directionMismatch, "a card payment is never matched to a purchase")
        }
        let purchase = try line(s, "GROCERY")
        XCTAssertThrowsError(try repo.confirm(lineId: purchase.id, transactionId: euro.id)) {
            XCTAssertEqual($0 as? StatementReviewError, .currencyMismatch)
        }
        try repo.confirm(lineId: purchase.id, transactionId: grocery.id)
        // The same purchase can't back a line on another statement of the same card.
        let again = try saveCard(purchases: ["07/02 GROCERY OUTLET 100.00"])
        XCTAssertThrowsError(try repo.confirm(lineId: try line(again, "GROCERY").id, transactionId: grocery.id)) {
            XCTAssertEqual($0 as? StatementReviewError, .transactionAlreadyMatched)
        }
        XCTAssertThrowsError(try repo.confirm(lineId: purchase.id, transactionId: grocery.id)) {
            XCTAssertEqual($0 as? StatementReviewError, .lineAlreadyResolved)
        }
    }

    // MARK: Create, skip

    func testAddMissingPurchaseUsesTransactionDateAndSuggestions() throws {
        let s = try saveCard(purchases: ["07/12 07/14 AMAZON.COM*AB12CD SEATTLE WA 25.00"])
        let l = try line(s, "AMAZON")
        XCTAssertEqual(l.status, .unmatched)
        let d = try repo.proposedNewTransaction(lineId: l.id, categories: categories, paymentMethods: [chase, wells],
                                                suggester: HeuristicCategorySuggestionService())
        XCTAssertEqual(d.type, .expense); XCTAssertEqual(d.merchant, "Amazon"); XCTAssertEqual(d.paymentMethodId, chase.id)
        XCTAssertEqual(categories.first { $0.id == d.categoryId }?.name, "Shopping")
        XCTAssertTrue(d.categorySuggested)

        let before = try julyTotals().expenseMinorUnits
        let id = try repo.createTransaction(lineId: l.id, decision: d)
        let t = try repo.moneyTransaction(id: id)
        XCTAssertEqual(t.transactionDate, day(7, 12), "the purchase date, not the posting date")
        XCTAssertEqual(t.source, .statementImport); XCTAssertEqual(t.amountMinorUnits, 2_500)
        XCTAssertEqual(t.notes, "From statement: AMAZON.COM*AB12CD SEATTLE WA")
        XCTAssertEqual(l.status, .created)
        XCTAssertEqual(try julyTotals().expenseMinorUnits, before + 2_500)

        try repo.undo(lineId: l.id)
        XCTAssertThrowsError(try repo.moneyTransaction(id: id), "undo deletes the transaction it added")
        XCTAssertEqual(l.status, .unmatched)
        XCTAssertEqual(try julyTotals().expenseMinorUnits, before)
    }

    func testSkipAndUndoSkip() throws {
        let s = try saveCard(purchases: ["07/03 SOMETHING ELSE 9.00"])
        let l = try line(s, "SOMETHING")
        try repo.skip(lineId: l.id)
        XCTAssertEqual(l.status, .skipped)
        XCTAssertThrowsError(try repo.createTransaction(lineId: l.id, decision: NewTransactionDecision(type: .expense, title: "x")))
        try repo.undo(lineId: l.id)
        XCTAssertEqual(l.status, .unmatched)
    }

    // MARK: Bulk

    func testBulkConfirmOnlyStrongAndAllOrNothing() throws {
        let walmart = try addTransaction(8_549, "Walmart", day(7, 5), pm: chase.id)
        try addTransaction(5_000, "Joes Diner", day(7, 6), pm: chase.id)
        let s = try saveCard(purchases: ["07/05 WM SUPERCENTER #1234 85.49", "07/06 JOES DINER 59.00", "07/07 UNKNOWN SHOP 3.00"])
        let items = try repo.bulkConfirmCandidates(statementId: s.id)
        XCTAssertEqual(items.map(\.transactionId), [walmart.id], "only the strong, exact-amount match")

        XCTAssertThrowsError(try repo.bulkConfirm(items + [BulkConfirmItem(lineId: UUID(), transactionId: walmart.id)]))
        XCTAssertEqual(try line(s, "WM SUPER").status, .suggested, "a failed bulk confirm saves nothing")

        XCTAssertEqual(try repo.bulkConfirm(items), 1)
        XCTAssertEqual(try line(s, "WM SUPER").status, .matched)
        XCTAssertEqual(try repo.bulkConfirmCandidates(statementId: s.id), [])
    }

    // MARK: The $100 repayment

    func testCardRepaymentIsOneTransferAndSpendingStaysOneHundred() throws {
        // 1–2. $100 groceries on the Chase card; the card statement is imported.
        let card = try saveCard(purchases: ["07/02 GROCERY OUTLET 100.00"], payments: ["07/21 AUTOPAY PAYMENT THANK YOU -100.00"])
        let grocery = try line(card, "GROCERY")
        let groceryDecision = try repo.proposedNewTransaction(lineId: grocery.id, categories: categories, paymentMethods: [chase, wells],
                                                              suggester: HeuristicCategorySuggestionService())
        try repo.createTransaction(lineId: grocery.id, decision: groceryDecision)

        // 3–4. Chase is paid $100 from Wells Fargo; the bank statement is imported.
        let bank = try saveBank(withdrawals: ["07/20 CHASE CREDIT CRD AUTOPAY 100.00 900.00"])
        let bankLine = try line(bank, "CHASE")
        XCTAssertEqual(bankLine.kind, .cardPayment)
        let transfer = try repo.proposedNewTransaction(lineId: bankLine.id, categories: categories, paymentMethods: [chase, wells],
                                                       suggester: HeuristicCategorySuggestionService())
        XCTAssertEqual(transfer.type, .transfer)
        XCTAssertEqual(transfer.paymentMethodId, wells.id); XCTAssertEqual(transfer.transferDestinationPaymentMethodId, chase.id)
        let transferId = try repo.createTransaction(lineId: bankLine.id, decision: transfer)

        // The card's payment credit is the other side of the same transfer.
        let cardPayment = try line(card, "AUTOPAY")
        let counterparts = try repo.transferCounterparts(lineId: bankLine.id, calendar: cal)
        XCTAssertEqual(counterparts.map(\.id), [cardPayment.id])
        try repo.pairTransfer(lineId: bankLine.id, counterpartId: cardPayment.id)
        XCTAssertEqual(cardPayment.status, .matched); XCTAssertEqual(cardPayment.matchedTransactionId, transferId)

        let totals = try julyTotals()
        XCTAssertEqual(totals.expenseMinorUnits, 10_000, "spending is $100, not $200 or $300")
        XCTAssertEqual(totals.incomeMinorUnits, 0)
        let all = try TransactionRepository(context: context).allRecords()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.filter { $0.transactionType == .transfer }.count, 1)
        XCTAssertEqual(try repo.fetchStatement(id: card.id)?.reconciliationStatus, .reconciled)

        // A transfer can back one line per account, not two lines on the same account.
        let another = try saveCard(purchases: [], payments: ["07/21 AUTOPAY PAYMENT THANK YOU -100.00"])
        XCTAssertThrowsError(try repo.confirm(lineId: try line(another, "AUTOPAY").id, transactionId: transferId)) {
            XCTAssertEqual($0 as? StatementReviewError, .transactionAlreadyMatched)
        }

        // Undoing the bank import removes the transfer it added and releases the card's payment line.
        try repo.rollbackImport(statementId: bank.id)
        XCTAssertThrowsError(try repo.moneyTransaction(id: transferId))
        XCTAssertEqual(cardPayment.status, .unmatched)
        XCTAssertNil(try repo.fetchStatement(id: bank.id))
        XCTAssertEqual(try julyTotals().expenseMinorUnits, 10_000, "the grocery expense is untouched")
    }

    // MARK: Duplicates and gaps

    func testOverlappingStatementsAndIdenticalLines() throws {
        let first = try saveCard(purchases: ["07/02 GROCERY OUTLET 100.00"])
        let d = try repo.proposedNewTransaction(lineId: try line(first, "GROCERY").id, categories: categories,
                                                paymentMethods: [chase], suggester: HeuristicCategorySuggestionService())
        let created = try repo.createTransaction(lineId: try line(first, "GROCERY").id, decision: d)

        // The next statement repeats the line (overlapping periods).
        let second = try saveCard(purchases: ["07/02 GROCERY OUTLET 100.00", "07/15 COFFEE CART 4.50", "07/15 COFFEE CART 4.50"])
        let repeated = try line(second, "GROCERY")
        XCTAssertEqual(try repo.overlappingDuplicates(statementId: second.id, calendar: cal)[repeated.id]?.matchedTransactionId, created)
        XCTAssertNil(try repo.fetchMatches(lineIds: [repeated.id]).first { $0.transactionId == created && $0.status == .suggested },
                     "a transaction already backing the first statement isn't suggested again")
        // Two identical coffees in one statement are flagged but kept as two lines.
        let groups = try repo.identicalLineGroups(statementId: second.id, calendar: cal)
        XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(try repo.fetchLines(statementId: second.id).count, 3)
    }

    func testTransactionsMissingFromTheStatement() throws {
        let coffee = try addTransaction(450, "Coffee", day(7, 10), pm: chase.id)
        try addTransaction(700, "Late in the period", day(7, 30), pm: chase.id)
        try addTransaction(900, "Other account", day(7, 10), pm: wells.id)
        let grocery = try addTransaction(10_000, "Grocery Outlet", day(7, 2), pm: chase.id)
        let s = try saveCard(purchases: ["07/02 GROCERY OUTLET 100.00"])
        try repo.confirm(lineId: try line(s, "GROCERY").id, transactionId: grocery.id)
        let missing = try repo.appTransactionsMissingFromStatement(statementId: s.id, calendar: cal)
        XCTAssertEqual(missing.map(\.id), [coffee.id], "other accounts, confirmed lines and the last days of the period are left out")
    }

    func testIncompleteWhenLinesCouldNotBeRead() throws {
        let p = preview(["Chase", "Card ending in 1111", "Opening/Closing Date 07/01/2026 - 07/31/2026", "New Balance $0.00", "Purchases",
                         "07/03 SHOP 9.00", "07/04 NO AMOUNT HERE", "07/05 OTHER SHOP 2.00"])
        XCTAssertEqual(p.parse.issues.count, 1)
        let s = try repo.saveStatement(p, filename: "x", fingerprint: "x", paymentMethodId: chase.id, config: ReconciliationConfig(), calendar: cal)
        for l in try repo.fetchLines(statementId: s.id) { try repo.skip(lineId: l.id) }
        XCTAssertEqual(s.reconciliationStatus, .incomplete, "a statement with unread lines is never called reconciled")
    }
}
