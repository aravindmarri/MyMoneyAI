import Foundation
import SwiftData
import XCTest
@testable import TallySeam

/// Statement matching (Phase B). Synthetic data only; fixed calendar.
final class MerchantNormalizerTests: XCTestCase {
    func testWalmartSpellingsBecomeOneMerchant() {
        for s in ["WAL-MART STORE #2456", "WALMART SUPERCENTER", "WM SUPERCENTER #1234", "WALMART.COM", "Walmart", "POS PURCHASE WAL-MART #12"] {
            XCTAssertEqual(StatementMerchantNormalizer.normalize(s), "walmart", s)
        }
    }

    func testPrefixesStoreNumbersAndLocations() {
        XCTAssertEqual(StatementMerchantNormalizer.normalize("PURCHASE AUTHORIZED ON 10/04 STARBUCKS STORE 1234 SEATTLE WA"), "starbucks")
        XCTAssertEqual(StatementMerchantNormalizer.normalize("SQ *BLUE BOTTLE 1234 OAKLAND CA"), "blue bottle")
        XCTAssertEqual(StatementMerchantNormalizer.normalize("AMAZON.COM*AB12CD SEATTLE WA"), "amazon")
        XCTAssertEqual(StatementMerchantNormalizer.normalize("AMZN Mktp US*2K4"), "amazon")
        XCTAssertEqual(StatementMerchantNormalizer.normalize("TST* JOES DINER"), "joes diner")
    }

    func testLearnedAliasesWin() {
        XCTAssertEqual(StatementMerchantNormalizer.normalize("ACME HOLDINGS 4411", learnedAliases: ["acme holdings": "corner gym"]), "corner gym")
    }

    func testSimilarity() {
        XCTAssertEqual(StatementMerchantNormalizer.similarity("walmart", "walmart"), 1)
        XCTAssertGreaterThan(StatementMerchantNormalizer.similarity("blue bottle", "blue bottle coffee"), 0.8)
        XCTAssertLessThan(StatementMerchantNormalizer.similarity("walmart", "netflix"), 0.4)
        XCTAssertEqual(StatementMerchantNormalizer.similarity("", "walmart"), 0)
        XCTAssertEqual(StatementMerchantNormalizer.levenshtein("kitten", "sitting"), 3)
    }
}

final class StatementMatchingTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private let card = UUID(), bank = UUID(), otherCard = UUID()

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private func expense(_ amount: Int64, _ merchant: String, _ date: Date, pm: UUID? = nil, currency: String = "USD", refund: Bool = false) -> TransactionRecord {
        TransactionRecord(transactionDate: date, amountMinorUnits: amount, currencyCode: currency, merchant: merchant, title: merchant,
                          transactionType: .expense, paymentMethodId: pm, isRefund: refund)
    }
    private func line(_ amount: Int64, _ desc: String, _ date: Date, posted: Date? = nil, _ dir: StatementDirection = .moneyOut,
                      kind: StatementLineKind = .purchase, currency: String = "USD") -> StatementLineInput {
        StatementLineInput(id: UUID(), transactionDate: date, postingDate: posted, description: desc, amountMinorUnits: amount,
                           currencyCode: currency, direction: dir, kind: kind)
    }
    private func service(_ w: MatchDateWindow = .twoDays) -> StatementReconciliationService {
        var c = ReconciliationConfig(); c.window = w
        return StatementReconciliationService(config: c, calendar: cal)
    }
    private var cardAccount: ReconciliationAccount { ReconciliationAccount(paymentMethodId: card, isCreditCard: true, displayName: "Card") }
    private var bankAccount: ReconciliationAccount { ReconciliationAccount(paymentMethodId: bank, isCreditCard: false, displayName: "Bank") }

    func testWalmartPostedTwoDaysLaterIsSuggested() {
        let walmart = expense(8_549, "Walmart", at(2026, 11, 12), pm: card)
        let l = line(8_549, "WAL-MART STORE #2456", at(2026, 11, 14))
        let r = service().reconcile(lines: [l], existing: [walmart], account: cardAccount)[0]
        XCTAssertEqual(r.suggestion?.transactionId, walmart.id)
        XCTAssertEqual(r.suggestion?.strength, .strong)
        XCTAssertEqual(r.suggestion?.dateDifferenceDays, 2)
        XCTAssertTrue(r.suggestion?.reasons.contains("Same amount") == true)
        XCTAssertTrue(r.suggestion?.reasons.contains { $0.contains("2 days apart") } == true)

        // Without a payment method on the expense it's still suggested, but only as possible.
        let noMethod = expense(8_549, "Walmart", at(2026, 11, 12))
        XCTAssertEqual(service().reconcile(lines: [l], existing: [noMethod], account: cardAccount)[0].suggestion?.strength, .possible)
    }

    func testDateDifferencesInBothDirectionsAndWindows() {
        let t = expense(1_000, "Bookshop", at(2026, 3, 10), pm: card)
        for (d, expected) in [(10, 0), (11, 1), (12, 2), (8, -2), (9, -1)] {
            let c = service().candidate(line: line(1_000, "BOOKSHOP", at(2026, 3, d)), transaction: t, account: cardAccount)
            XCTAssertEqual(c?.dateDifferenceDays, expected, "day \(d)")
            XCTAssertEqual(c?.strength, .strong, "day \(d)")
        }
        // Three days with the default window: still a candidate, explained, never strong.
        let three = service().candidate(line: line(1_000, "BOOKSHOP", at(2026, 3, 13)), transaction: t, account: cardAccount)
        XCTAssertNotNil(three); XCTAssertNotEqual(three?.strength, .strong)
        XCTAssertTrue(three?.reasons.contains { $0.contains("outside your ± 2-day window") } == true)
        // A weekend posting delay (Friday → Monday) fits a ±3 window.
        XCTAssertEqual(service(.threeDays).candidate(line: line(1_000, "BOOKSHOP", at(2026, 3, 13)), transaction: t, account: cardAccount)?.strength, .strong)
        // Same-day-only window.
        XCTAssertNotEqual(service(.exact).candidate(line: line(1_000, "BOOKSHOP", at(2026, 3, 11)), transaction: t, account: cardAccount)?.strength, .strong)
        // Far away: no candidate at all.
        XCTAssertNil(service().candidate(line: line(1_000, "BOOKSHOP", at(2026, 3, 20)), transaction: t, account: cardAccount))
    }

    func testPostingDateIsUsedWhenCloser() {
        let t = expense(2_000, "Cinema", at(2026, 5, 20), pm: card)
        let l = line(2_000, "CINEMA", at(2026, 5, 16), posted: at(2026, 5, 20))
        let c = service().candidate(line: l, transaction: t, account: cardAccount)
        XCTAssertEqual(c?.dateDifferenceDays, 0)
        XCTAssertTrue(c?.reasons.first == "Same date")
    }

    func testCalendarDaysNotElapsedHoursAcrossMonthAndYearEnds() {
        let s = service()
        XCTAssertEqual(s.calendarDays(from: at(2026, 12, 31, 23, 30), to: at(2027, 1, 1, 0, 30)), 1)
        XCTAssertEqual(s.calendarDays(from: at(2026, 1, 31, 8), to: at(2026, 2, 1, 22)), 1)
        XCTAssertEqual(s.calendarDays(from: at(2026, 3, 8, 1), to: at(2026, 3, 8, 23)), 0, "a DST change day is still one day")
        let t = expense(500, "Cafe", at(2026, 12, 31, 23, 30), pm: card)
        XCTAssertEqual(s.candidate(line: line(500, "CAFE", at(2027, 1, 1, 0, 30)), transaction: t, account: cardAccount)?.dateDifferenceDays, 1)
    }

    func testHardRulesCurrencyAndDirection() {
        let t = expense(1_000, "Shop", at(2026, 6, 1), pm: card)
        XCTAssertNil(service().candidate(line: line(1_000, "SHOP", at(2026, 6, 1), currency: "EUR"), transaction: t, account: cardAccount),
                     "different currencies never match")
        XCTAssertNil(service().candidate(line: line(1_000, "SHOP", at(2026, 6, 1), .moneyIn, kind: .refund), transaction: t, account: cardAccount),
                     "money in doesn't match a purchase")
        let refund = expense(1_000, "Shop", at(2026, 6, 3), pm: card, refund: true)
        XCTAssertNotNil(service().candidate(line: line(1_000, "SHOP", at(2026, 6, 3), .moneyIn, kind: .refund), transaction: refund, account: cardAccount))
    }

    func testCardRepaymentMatchesTransfersNeverPurchases() {
        // $100 groceries on the card, then $100 paid to the card from the bank.
        let groceries = expense(10_000, "Groceries", at(2026, 7, 1), pm: card)
        let repayment = TransactionRecord(transactionDate: at(2026, 7, 20), amountMinorUnits: 10_000, title: "Card payment",
                                          transactionType: .transfer, paymentMethodId: bank, transferDestinationPaymentMethodId: card)
        let existing = [groceries, repayment]

        // Bank statement: money out to the card.
        let bankLine = line(10_000, "CHASE CREDIT CRD AUTOPAY", at(2026, 7, 21), kind: .cardPayment)
        let b = service().reconcile(lines: [bankLine], existing: existing, account: bankAccount)[0]
        XCTAssertEqual(b.suggestion?.transactionId, repayment.id)
        XCTAssertFalse(b.candidates.contains { $0.transactionId == groceries.id })

        // Card statement: the payment credit.
        let cardLine = line(10_000, "AUTOPAY PAYMENT THANK YOU", at(2026, 7, 21), .moneyIn, kind: .cardPayment)
        XCTAssertEqual(service().reconcile(lines: [cardLine], existing: existing, account: cardAccount)[0].suggestion?.transactionId, repayment.id)
        // A transfer to a different card is not this card's payment.
        let toOther = TransactionRecord(transactionDate: at(2026, 7, 20), amountMinorUnits: 10_000, title: "Other card",
                                        transactionType: .transfer, paymentMethodId: bank, transferDestinationPaymentMethodId: otherCard)
        XCTAssertNil(service().candidate(line: cardLine, transaction: toOther, account: cardAccount))

        // Totals are untouched by matching: one $100 expense.
        let total = FinanceCalculationService(calendar: cal).summary(of: existing, in: cal.monthRange(containing: at(2026, 7, 15)), currencyCode: "USD")
        XCTAssertEqual(total.expenseMinorUnits, 10_000)
    }

    func testTipDifferenceNeedsReview() {
        let dinner = expense(5_000, "Joes Diner", at(2026, 8, 1), pm: card)
        let c = service().candidate(line: line(5_900, "TST* JOES DINER", at(2026, 8, 2)), transaction: dinner, account: cardAccount)
        XCTAssertNotNil(c)
        XCTAssertNotEqual(c?.strength, .strong, "an amount difference is never a strong match")
        XCTAssertEqual(c?.amountDifferenceMinorUnits, 900)
        XCTAssertTrue(c?.reasons.contains { $0.contains("tip") } == true)
        XCTAssertNil(service().candidate(line: line(9_000, "TST* JOES DINER", at(2026, 8, 2)), transaction: dinner, account: cardAccount),
                     "a large difference isn't a candidate")
    }

    func testIdenticalPurchasesMatchOneToOne() {
        let a = expense(450, "Starbucks", at(2026, 9, 3, 8), pm: card), b = expense(450, "Starbucks", at(2026, 9, 3, 15), pm: card)
        let l1 = line(450, "STARBUCKS #1", at(2026, 9, 3)), l2 = line(450, "STARBUCKS #1", at(2026, 9, 3))
        let r = service().reconcile(lines: [l1, l2], existing: [a, b], account: cardAccount)
        XCTAssertEqual(Set(r.compactMap { $0.suggestion?.transactionId }), [a.id, b.id], "each coffee backs one line")
        XCTAssertFalse(r[0].isAmbiguous); XCTAssertFalse(r[1].isAmbiguous)

        // Only one coffee recorded: the second line is not matched to it again.
        let one = service().reconcile(lines: [l1, l2], existing: [a], account: cardAccount)
        XCTAssertEqual(one.compactMap(\.suggestion).count, 1)
        XCTAssertEqual(one.first { $0.suggestion == nil }?.note, "The likely matches are already suggested for other lines.")
    }

    func testEquallyPlausibleCandidatesAreAllShown() {
        let a = expense(2_000, "Gas Station", at(2026, 10, 5), pm: card), b = expense(2_000, "Gas Station", at(2026, 10, 5), pm: card)
        let r = service().reconcile(lines: [line(2_000, "GAS STATION", at(2026, 10, 5))], existing: [a, b], account: cardAccount)[0]
        XCTAssertTrue(r.isAmbiguous)
        XCTAssertEqual(r.candidates.count, 2)
    }

    func testAlreadyConfirmedTransactionsAreSkippedAndPaymentMethodMatters() {
        let t = expense(3_000, "Pharmacy", at(2026, 4, 2), pm: card)
        let l = line(3_000, "PHARMACY", at(2026, 4, 2))
        XCTAssertNil(service().reconcile(lines: [l], existing: [t], account: cardAccount, alreadyMatched: [t.id])[0].suggestion)
        let elsewhere = expense(3_000, "Pharmacy", at(2026, 4, 2), pm: otherCard)
        let c = service().candidate(line: l, transaction: elsewhere, account: cardAccount)
        XCTAssertTrue(c?.reasons.contains("Recorded on a different payment method") == true)
        XCTAssertLessThan(c?.score ?? 100, service().candidate(line: l, transaction: t, account: cardAccount)?.score ?? 0)
    }
}

@MainActor
final class StatementRepositoryTests: XCTestCase {
    private var persistence: PersistenceService!
    private var repo: StatementRepository!
    private var cardId: UUID!
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    override func setUp() async throws {
        persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        repo = StatementRepository(context: persistence.context)
        let pm = PaymentMethod(name: "Capital One Credit", type: .creditCard, lastFourDigits: "4321")
        persistence.context.insert(pm)
        cardId = pm.id
        // The user's own record of the Walmart purchase, a day before the statement's date.
        persistence.context.insert(MoneyTransaction(record: TransactionRecord(
            transactionDate: cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10))!, amountMinorUnits: 8_549,
            merchant: "Walmart", title: "Walmart", transactionType: .expense, paymentMethodId: pm.id)))
        try persistence.context.save()
    }

    private func cardPreview() -> StatementPreview {
        StatementImportService.preview(text: DocumentText(pages: [DocumentPage(index: 0, lines: StatementFixtures.cardLines, source: .plainText)]),
                                       format: .text, defaultCurrency: "USD", calendar: cal)
    }

    func testSaveStatementCreatesLinesAndSuggestionsOnly() throws {
        let before = try persistence.context.fetchCount(FetchDescriptor<MoneyTransaction>())
        let s = try repo.saveStatement(cardPreview(), filename: "synthetic.pdf", fingerprint: "fp1", paymentMethodId: cardId,
                                       config: ReconciliationConfig(), calendar: cal)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<MoneyTransaction>()), before, "matching never adds transactions")
        let lines = try repo.fetchLines(statementId: s.id)
        XCTAssertEqual(lines.count, 4)
        let walmart = try XCTUnwrap(lines.first { $0.normalizedMerchant == "walmart" })
        XCTAssertEqual(walmart.status, .suggested)
        let m = try XCTUnwrap(try repo.fetchMatches(lineIds: [walmart.id]).first { $0.isPrimary })
        XCTAssertEqual(m.strength, .strong)
        XCTAssertEqual(lines.filter { $0.status == .unmatched }.count, 3)
        let account = try XCTUnwrap(try repo.financialAccount(id: s.accountId))
        XCTAssertEqual(account.accountType, .creditCard); XCTAssertEqual(account.linkedPaymentMethodId, cardId)
        XCTAssertEqual(account.lastFourDigits, "4321")
        XCTAssertEqual(s.closingBalance, 24_350); XCTAssertEqual(s.reconciliationStatus, .inProgress)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<ImportSession>()), 1)
    }

    func testDuplicateDocumentAndWrongTypeAreRefused() throws {
        try repo.saveStatement(cardPreview(), filename: "a.pdf", fingerprint: "same", paymentMethodId: cardId, config: ReconciliationConfig(), calendar: cal)
        XCTAssertThrowsError(try repo.saveStatement(cardPreview(), filename: "a copy.pdf", fingerprint: "same", paymentMethodId: cardId,
                                                    config: ReconciliationConfig(), calendar: cal)) {
            guard case StatementImportError.duplicateDocument = $0 else { return XCTFail("\($0)") }
        }
        var receipt = cardPreview(); receipt.kind = .receipt
        XCTAssertThrowsError(try repo.saveStatement(receipt, filename: "r", fingerprint: "r", paymentMethodId: cardId, config: ReconciliationConfig(), calendar: cal)) {
            XCTAssertEqual($0 as? StatementImportError, .notAStatement)
        }
        XCTAssertThrowsError(try repo.saveStatement(cardPreview(), filename: "x", fingerprint: "x", paymentMethodId: nil, config: ReconciliationConfig(), calendar: cal))
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<ImportedStatement>()), 1, "failed saves keep nothing")
        // A second statement for the same card reuses the account.
        try repo.saveStatement(cardPreview(), filename: "next.pdf", fingerprint: "other", paymentMethodId: cardId, config: ReconciliationConfig(), calendar: cal)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<FinancialAccount>()), 1)
    }

    func testRefreshWithNarrowerWindowAndUndoImport() throws {
        let s = try repo.saveStatement(cardPreview(), filename: "a.pdf", fingerprint: "fp", paymentMethodId: cardId, config: ReconciliationConfig(), calendar: cal)
        var exact = ReconciliationConfig(); exact.window = .exact
        try repo.refreshSuggestions(statementId: s.id, config: exact, calendar: cal)
        let walmart = try XCTUnwrap(try repo.fetchLines(statementId: s.id).first { $0.normalizedMerchant == "walmart" })
        let m = try repo.fetchMatches(lineIds: [walmart.id]).first { $0.isPrimary }
        XCTAssertNotEqual(m?.strength, .strong, "a 1-day gap is outside a same-day window")

        let txCount = try persistence.context.fetchCount(FetchDescriptor<MoneyTransaction>())
        try repo.deleteImport(statementId: s.id)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<ImportedStatement>()), 0)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<StatementTransaction>()), 0)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<ReconciliationMatch>()), 0)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<ImportSession>()), 0)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<MoneyTransaction>()), txCount, "undo never touches transactions")
    }

    func testDeleteAllDataClearsStatementData() throws {
        try repo.saveStatement(cardPreview(), filename: "a.pdf", fingerprint: "fp", paymentMethodId: cardId, config: ReconciliationConfig(), calendar: cal)
        let root = FileManager.default.temporaryDirectory.appending(path: "DeleteAll-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ReceiptStorageService(rootURL: root)
        try BackupService(context: persistence.context, storage: storage).deleteAllData()
        for count in [try persistence.context.fetchCount(FetchDescriptor<ImportedStatement>()),
                      try persistence.context.fetchCount(FetchDescriptor<StatementTransaction>()),
                      try persistence.context.fetchCount(FetchDescriptor<ReconciliationMatch>()),
                      try persistence.context.fetchCount(FetchDescriptor<FinancialAccount>())] {
            XCTAssertEqual(count, 0)
        }
    }

    func testLearnedAliasIsStoredOncePerSpelling() throws {
        try repo.learnAlias(statementDescription: "ACME HOLDINGS 4411", merchant: "Corner Gym")
        try repo.learnAlias(statementDescription: "ACME HOLDINGS 9", merchant: "Corner Gym")
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<MerchantAlias>()), 1)
        XCTAssertEqual(try repo.learnedAliases(), ["acme holdings": "corner gym"])
        XCTAssertEqual(try persistence.context.fetch(FetchDescriptor<MerchantAlias>()).first?.confirmations, 2)
    }

    func testWindowPreference() throws {
        let suite = "ReconciliationPrefs-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReconciliationPreferences.window(d), .twoDays)
        d.set(7, forKey: ReconciliationPreferences.windowKey)
        XCTAssertEqual(ReconciliationPreferences.config(d).window, .sevenDays)
        d.set(4, forKey: ReconciliationPreferences.windowKey)
        XCTAssertEqual(ReconciliationPreferences.window(d), .twoDays, "unknown values fall back to the default")
    }
}

/// The 2.0.0 → 3.0.0 upgrade that adds the statement tables, on a real on-disk store.
@MainActor
final class SchemaV3MigrationTests: XCTestCase {
    private var folder: URL!
    private var url: URL { folder.appending(path: "TallySeam.store") }
    private let txId = UUID()

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "MigrationV3-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    /// Writes a store exactly as app builds 1.0 (19)–(22) did: schema 2.0.0.
    private func writeVersion2Store() throws {
        let schema = Schema(versionedSchema: TallySeamSchemaV2.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.insert(MoneyTransaction(record: TransactionRecord(id: txId, transactionDate: Date(timeIntervalSince1970: 1_790_000_000),
                                                                  amountMinorUnits: 2_500, title: "Synthetic salary", transactionType: .income,
                                                                  countedMonth: 202_611)))
        context.insert(PaymentMethod(name: "Wells Fargo Debit", type: .debitCard))
        try context.save()
    }

    func testA_Version2StoreCanBeWritten() throws {
        try writeVersion2Store()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testB_Version2StoreUpgradesWithoutLosingData() throws {
        try writeVersion2Store()
        let updated = try PersistenceService(storeURL: url)
        let kept = try XCTUnwrap(TransactionRepository(context: updated.context).fetch(id: txId))
        XCTAssertEqual(kept.amountMinorUnits, 2_500); XCTAssertEqual(kept.countedMonth, 202_611)
        XCTAssertEqual(try updated.context.fetchCount(FetchDescriptor<PaymentMethod>()), 1)
        XCTAssertEqual(try updated.context.fetchCount(FetchDescriptor<ImportedStatement>()), 0)
    }

    func testC_UpgradedStoreAcceptsNewData() throws {
        try writeVersion2Store()
        let updated = try PersistenceService(storeURL: url)
        updated.context.insert(MerchantAlias(aliasKey: "wm supercenter", merchantKey: "walmart"))
        try updated.context.save()
        let reopened = try PersistenceService(storeURL: url)
        XCTAssertEqual(try reopened.context.fetchCount(FetchDescriptor<MerchantAlias>()), 1)
    }
}
