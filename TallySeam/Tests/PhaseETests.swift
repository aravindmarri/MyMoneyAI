import Foundation
import SwiftData
import XCTest
@testable import TallySeam

/// Phase E: statement data in backups, removing statement data, the description assistant, and
/// matching performance. Synthetic data only.
@MainActor
final class StatementBackupTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func storage() throws -> ReceiptStorageService {
        let root = FileManager.default.temporaryDirectory.appending(path: "PhaseE-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ReceiptStorageService(rootURL: root)
    }

    /// A device with a Capital One card, a Walmart expense and the card statement saved, the Walmart
    /// line confirmed and the Amazon line added as a new transaction.
    private func makeDevice() throws -> (PersistenceService, StatementRepository, ImportedStatement) {
        let p = try PersistenceService(inMemory: true)
        try p.seedDefaultsIfNeeded()
        let card = PaymentMethod(name: "Capital One Credit", type: .creditCard, lastFourDigits: "4321")
        p.context.insert(card)
        let walmart = TransactionRecord(transactionDate: cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9))!,
                                        amountMinorUnits: 8_549, merchant: "Walmart", title: "Walmart", transactionType: .expense, paymentMethodId: card.id)
        p.context.insert(MoneyTransaction(record: walmart))
        try p.context.save()
        let repo = StatementRepository(context: p.context)
        let preview = StatementImportService.preview(text: DocumentText(pages: [DocumentPage(index: 0, lines: StatementFixtures.cardLines, source: .plainText)]),
                                                     format: .text, defaultCurrency: "USD", calendar: cal)
        let s = try repo.saveStatement(preview, filename: "synthetic.pdf", fingerprint: "fp-card", paymentMethodId: card.id,
                                       config: ReconciliationConfig(), calendar: cal)
        let lines = try repo.fetchLines(statementId: s.id)
        try repo.confirm(lineId: try XCTUnwrap(lines.first { $0.normalizedMerchant == "walmart" }).id, transactionId: walmart.id)
        let amazon = try XCTUnwrap(lines.first { $0.normalizedMerchant == "amazon" })
        try repo.createTransaction(lineId: amazon.id, decision: NewTransactionDecision(type: .expense, title: "Amazon", merchant: "Amazon",
                                                                                         paymentMethodId: card.id))
        try repo.learnAlias(statementDescription: "ACME HOLDINGS 4411", merchant: "Corner Gym")
        return (p, repo, s)
    }

    func testStatementsRoundTripThroughABackup() throws {
        let (device, _, statement) = try makeDevice()
        let payload = try BackupService(context: device.context, storage: try storage()).makePayload()
        XCTAssertEqual(payload.reconciliation?.statements.count, 1)
        let decoded = try BackupService.decode(try BackupService.encode(payload))
        XCTAssertEqual(decoded, payload)

        let fresh = try PersistenceService(inMemory: true)
        try fresh.seedDefaultsIfNeeded()
        let summary = try BackupService(context: fresh.context, storage: try storage()).restore(decoded)
        XCTAssertEqual(summary.statementsAdded, 1)
        let repo = StatementRepository(context: fresh.context)
        let restored = try XCTUnwrap(try repo.fetchStatement(id: statement.id))
        XCTAssertEqual(restored.closingBalance, 24_350)
        let lines = try repo.fetchLines(statementId: statement.id)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.first { $0.normalizedMerchant == "walmart" }?.status, .matched)
        XCTAssertEqual(lines.first { $0.normalizedMerchant == "amazon" }?.status, .created)
        XCTAssertEqual(try repo.learnedAliases()["acme holdings"], "corner gym")
        XCTAssertEqual(try repo.verifiedTransactionIds().count, 2, "verified spending survives the restore")
        XCTAssertFalse(try repo.fetchMatches(lineIds: Set(lines.map(\.id))).isEmpty)

        // Restoring the same backup again adds nothing.
        let again = try BackupService(context: fresh.context, storage: try storage()).restore(decoded)
        XCTAssertEqual(again.statementsAdded, 0); XCTAssertEqual(again.statementsSkipped, 1)
        XCTAssertEqual(try fresh.context.fetchCount(FetchDescriptor<StatementTransaction>()), 4)
    }

    func testLinksToTransactionsMissingFromTheBackupAreReleased() throws {
        let (device, _, statement) = try makeDevice()
        var payload = try BackupService(context: device.context, storage: try storage()).makePayload()
        payload.transactions.removeAll { $0.merchant == "Walmart" }
        let fresh = try PersistenceService(inMemory: true)
        try fresh.seedDefaultsIfNeeded()
        try BackupService(context: fresh.context, storage: try storage()).restore(payload)
        let walmart = try XCTUnwrap(try StatementRepository(context: fresh.context).fetchLines(statementId: statement.id).first { $0.normalizedMerchant == "walmart" })
        XCTAssertEqual(walmart.status, .unmatched)
        XCTAssertNil(walmart.matchedTransactionId)
    }

    func testBrokenStatementDataImportsNothing() throws {
        let (device, _, _) = try makeDevice()
        var payload = try BackupService(context: device.context, storage: try storage()).makePayload()
        payload.reconciliation?.lines[0].statementId = UUID()   // a line pointing at no statement
        let fresh = try PersistenceService(inMemory: true)
        try fresh.seedDefaultsIfNeeded()
        XCTAssertThrowsError(try BackupService(context: fresh.context, storage: try storage()).restore(payload)) {
            XCTAssertEqual($0 as? BackupError, .invalidContents)
        }
        XCTAssertEqual(try fresh.context.fetchCount(FetchDescriptor<MoneyTransaction>()), 0, "all or nothing")
        XCTAssertEqual(try fresh.context.fetchCount(FetchDescriptor<ImportedStatement>()), 0)
    }

    func testOldBackupsWithoutStatementsStillImport() throws {
        let payload = try BackupService.decode(Data(UpdateCompatibilityTests.frozenV1Backup.utf8))
        XCTAssertNil(payload.reconciliation)
        let fresh = try PersistenceService(inMemory: true)
        try fresh.seedDefaultsIfNeeded()
        XCTAssertEqual(try BackupService(context: fresh.context, storage: try storage()).restore(payload).statementsAdded, 0)
    }

    func testDeletingStatementDataKeepsTransactions() throws {
        let (device, repo, _) = try makeDevice()
        let before = try device.context.fetchCount(FetchDescriptor<MoneyTransaction>())
        XCTAssertEqual(try repo.deleteAllStatementData(), 1)
        XCTAssertEqual(try device.context.fetchCount(FetchDescriptor<MoneyTransaction>()), before, "including the one added from the statement")
        XCTAssertEqual(try device.context.fetchCount(FetchDescriptor<StatementTransaction>()), 0)
        XCTAssertEqual(try device.context.fetchCount(FetchDescriptor<ReconciliationMatch>()), 0)
        XCTAssertEqual(try device.context.fetchCount(FetchDescriptor<ImportSession>()), 0)
        XCTAssertEqual(try repo.verifiedTransactionIds(), [], "transactions are now unverified")
        XCTAssertEqual(try repo.learnedAliases().count, 1, "learned spellings are kept")
    }
}

final class DescriptionAssistantTests: XCTestCase {
    private let categories = ["Groceries", "Restaurants", "Shopping", "Other"]

    func testRuleBasedInsights() async {
        let a = RuleBasedDescriptionAssistant()
        let square = await a.insight(for: "SQ *BLUE BOTTLE 1234 OAKLAND CA", kind: .purchase, categoryNames: categories)
        XCTAssertEqual(square.merchantName, "Blue Bottle")
        XCTAssertTrue(square.explanation.contains("Square"))
        XCTAssertTrue(square.explanation.contains("store or reference number"))
        XCTAssertEqual(square.source, .rules)

        let payment = await a.insight(for: "CHASE CREDIT CRD AUTOPAY", kind: .cardPayment, categoryNames: categories)
        XCTAssertTrue(payment.explanation.contains("transfer"))
        let grocery = await a.insight(for: "GROCERY OUTLET 88", kind: .purchase, categoryNames: categories)
        XCTAssertEqual(grocery.categoryName, "Groceries")
        let interest = await a.insight(for: "INTEREST CHARGE ON PURCHASES", kind: .interest, categoryNames: categories)
        XCTAssertTrue(interest.explanation.contains("real expense"))
    }

    func testModelAnswersAreCheckedBeforeUse() {
        let fallback = DescriptionInsight(merchantName: "Fallback", categoryName: nil, explanation: "Rules.", source: .rules)
        let good = DescriptionAnswerParser.parse("Merchant: Blue Bottle Coffee\nCategory: restaurants\nExplanation: A coffee shop purchase.",
                                                 categoryNames: categories, fallback: fallback, source: .onDeviceModel)
        XCTAssertEqual(good.merchantName, "Blue Bottle Coffee"); XCTAssertEqual(good.categoryName, "Restaurants")
        XCTAssertEqual(good.source, .onDeviceModel)
        let unknownCategory = DescriptionAnswerParser.parse("Merchant: Corner Gym\nCategory: Fitness\nExplanation: Gym.", categoryNames: categories,
                                                            fallback: fallback, source: .onDeviceModel)
        XCTAssertNil(unknownCategory.categoryName, "only the user's own categories are accepted")
        for bad in ["Merchant: Store #4411 paid $85.49\nCategory: Shopping", "Category: Shopping", "nonsense",
                    "Merchant: This is a very long made up merchant name that goes on\nCategory: Other"] {
            XCTAssertEqual(DescriptionAnswerParser.parse(bad, categoryNames: categories, fallback: fallback, source: .onDeviceModel), fallback, bad)
        }
    }

    func testRulesAreUsedUnlessTheUserTurnsTheModelOn() throws {
        let suite = "Assistant-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertTrue(DescriptionAssistantFactory.make(defaults: d) is RuleBasedDescriptionAssistant)
        d.set(true, forKey: DescriptionAssistantFactory.preferenceKey)
        if !DescriptionAssistantFactory.isOnDeviceModelAvailable {
            XCTAssertTrue(DescriptionAssistantFactory.make(defaults: d) is RuleBasedDescriptionAssistant, "falls back where Apple Intelligence isn't available")
        }
    }
}

final class MatchingPerformanceTests: XCTestCase {
    func testLongStatementAgainstALongHistoryIsFast() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        let merchants = ["Walmart", "Starbucks", "Shell", "Target", "Amazon", "Corner Market", "Joes Diner", "Netflix"]
        var history: [TransactionRecord] = []
        for i in 0..<3_000 {
            let date = cal.date(byAdding: .hour, value: i * 3, to: start)!
            let amount = Int64(500 + (i * 37) % 9_000)
            let merchant = merchants[i % merchants.count]
            history.append(TransactionRecord(transactionDate: date, amountMinorUnits: amount, merchant: merchant, title: merchant,
                                             transactionType: .expense))
        }
        var lines: [StatementLineInput] = []
        for i in 0..<1_000 {
            let t = history[i * 3]
            let date = cal.date(byAdding: .day, value: 1, to: t.transactionDate)!
            let description = (t.merchant ?? "").uppercased() + " #" + String(i)
            lines.append(StatementLineInput(id: UUID(), transactionDate: date, postingDate: nil, description: description,
                                            amountMinorUnits: t.amountMinorUnits, currencyCode: "USD", direction: .moneyOut, kind: .purchase))
        }
        let service = StatementReconciliationService(calendar: cal)
        let began = Date()
        let results = service.reconcile(lines: lines, existing: history,
                                        account: ReconciliationAccount(paymentMethodId: nil, isCreditCard: true, displayName: "Card"))
        let seconds = Date().timeIntervalSince(began)
        XCTAssertEqual(results.count, 1_000)
        let suggested = results.filter { (r: LineReconciliation) -> Bool in r.suggestion != nil }.count
        XCTAssertGreaterThan(suggested, 900, "nearly every line finds its transaction")
        XCTAssertLessThan(seconds, 15, "1,000 lines against 3,000 transactions took \(seconds)s")
    }
}
