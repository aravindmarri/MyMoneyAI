import Foundation
import SwiftData
import XCTest
@testable import TallySeam

/// Phase D: statement balance checks, verified spending, and the 3.0.0 → 4.0.0 upgrade. Synthetic data only.
final class StatementBalanceTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Denver")!
        return c
    }()

    private func input(_ lines: [String], dropping: String? = nil, unread: Int? = nil) -> StatementBalanceInput {
        let p = StatementImportService.preview(text: DocumentText(pages: [DocumentPage(index: 0, lines: lines, source: .plainText)]),
                                               format: .text, defaultCurrency: "USD", calendar: cal)
        let h = p.header
        return StatementBalanceInput(
            isCreditCard: p.kind == .creditCardStatement, currencyCode: h.currencyCode, openingBalance: h.openingBalance,
            closingBalance: h.closingBalance, totalDeposits: h.totalDeposits, totalWithdrawals: h.totalWithdrawals,
            totalPaymentsAndCredits: h.totalPaymentsAndCredits, totalPurchases: h.totalPurchases, totalFees: h.totalFees,
            totalInterest: h.totalInterest,
            lines: p.parse.lines.filter { dropping == nil || !$0.description.contains(dropping!) }.map {
                StatementBalanceInput.Line(amountMinorUnits: $0.amountMinorUnits, direction: $0.direction, runningBalance: $0.runningBalance,
                                           page: $0.page, line: $0.line, isPending: $0.isPending)
            },
            unreadLineCount: unread ?? p.parse.issues.count)
    }

    func testBankStatementBalances() {
        let r = StatementBalanceValidator.validate(input(StatementFixtures.bankLines, unread: 0))
        XCTAssertEqual(r.verdict, .verified)
        XCTAssertTrue(r.checks.allSatisfy(\.result.isBalanced), "\(r.checks)")
        XCTAssertEqual(r.runningBalanceBreaks, [])
        XCTAssertEqual(r.checks.first { $0.id == "lines" }?.expected, 210_501)
    }

    func testUnreadLinesMeanTheBalanceIsNotProven() {
        // The fixture has one check with no amount; until it's entered the balance can't be proven.
        let r = StatementBalanceValidator.validate(input(StatementFixtures.bankLines))
        XCTAssertEqual(r.verdict, .notEnoughInformation)
        XCTAssertTrue(r.explanation.contains("couldn't be read"))
    }

    func testMissingRowIsFoundByTheRunningBalance() {
        let r = StatementBalanceValidator.validate(input(StatementFixtures.bankLines, dropping: "ATM", unread: 0))
        XCTAssertEqual(r.verdict, .differences)
        XCTAssertEqual(r.checks.first { $0.id == "lines" }?.result, .difference(10_000))
        XCTAssertEqual(r.checks.first { $0.id == "out" }?.result, .difference(10_000), "withdrawals read are $100 short of the printed total")
        let b = try? XCTUnwrap(r.runningBalanceBreaks.first)
        XCTAssertEqual(b?.line, 20, "the line right after the missing ATM withdrawal")
        XCTAssertEqual(b?.expected, 220_501); XCTAssertEqual(b?.printed, 210_501)
        XCTAssertTrue(r.explanation.contains("line 20"))
    }

    func testCardStatementFormula() {
        let r = StatementBalanceValidator.validate(input(StatementFixtures.cardLines))
        XCTAssertEqual(r.verdict, .verified)
        XCTAssertEqual(r.checks.first { $0.id == "summary" }?.expected, 24_350, "500 + 240.40 + 0 + 3.10 − 500")
        XCTAssertTrue(r.checks.allSatisfy(\.result.isBalanced), "\(r.checks)")
    }

    func testMisreadSummaryFigure() {
        var lines = StatementFixtures.cardLines
        lines[lines.firstIndex(of: "Purchases +$240.40")!] = "Purchases +$204.40"
        let r = StatementBalanceValidator.validate(input(lines))
        XCTAssertEqual(r.verdict, .differences)
        XCTAssertEqual(r.checks.first { $0.id == "lines" }?.result, .balanced, "the transactions themselves still add up")
        XCTAssertTrue(r.checks.first { $0.id == "summary" }?.result.isDifference == true)
    }

    func testNotEnoughInformationWithoutAnOpeningBalance() {
        var s = input(StatementFixtures.cardLines)
        s.openingBalance = nil
        let r = StatementBalanceValidator.validate(s)
        XCTAssertEqual(r.verdict, .notEnoughInformation)
        if case .notAvailable = r.checks.first(where: { $0.id == "lines" })?.result {} else { XCTFail("expected not available") }
    }

    func testPendingLinesAreLeftOut() {
        var s = input(StatementFixtures.cardLines)
        s.lines.append(.init(amountMinorUnits: 9_999, direction: .moneyOut, runningBalance: nil, page: 1, line: 99, isPending: true))
        XCTAssertEqual(StatementBalanceValidator.validate(s).verdict, .verified)
    }

    func testCoverageUsesTheSameRulesAsTotals() {
        let month = cal.monthRange(containing: cal.date(from: DateComponents(year: 2026, month: 7, day: 15))!)
        func d(_ day: Int, _ m: Int = 7) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day, hour: 12))! }
        let a = TransactionRecord(transactionDate: d(2), amountMinorUnits: 10_000, title: "Groceries", transactionType: .expense)
        let b = TransactionRecord(transactionDate: d(3), amountMinorUnits: 3_000, title: "Cash lunch", transactionType: .expense)
        let refund = TransactionRecord(transactionDate: d(4), amountMinorUnits: 1_000, title: "Return", transactionType: .expense, isRefund: true)
        let transfer = TransactionRecord(transactionDate: d(5), amountMinorUnits: 50_000, title: "Card payment", transactionType: .transfer)
        let euro = TransactionRecord(transactionDate: d(6), amountMinorUnits: 700, currencyCode: "EUR", title: "Abroad", transactionType: .expense)
        let earlyRent = TransactionRecord(transactionDate: d(30, 6), amountMinorUnits: 2_000, title: "July rent", transactionType: .expense, countedMonth: 202_607)
        let c = ReconciliationSummaryService.coverage(records: [a, b, refund, transfer, euro, earlyRent], verifiedIds: [a.id, refund.id, transfer.id],
                                                      range: month, currencyCode: "USD", calendar: cal)
        XCTAssertEqual(c.verifiedMinorUnits, 9_000, "100 − 10 refund; the transfer is never spending")
        XCTAssertEqual(c.unverifiedMinorUnits, 5_000, "cash lunch + rent counted in July")
        XCTAssertEqual(c.totalMinorUnits, 14_000)
        XCTAssertEqual(c.percentVerified, 64, "9000/14000 = 64.3%, rounded down")
        XCTAssertEqual(ReconciliationSummaryService.coverage(records: [], verifiedIds: [], range: month, currencyCode: "USD", calendar: cal).percentVerified, 0)
    }
}

/// The 3.0.0 → 4.0.0 upgrade that adds `runningBalance` to statement lines, on a real store.
@MainActor
final class SchemaV4MigrationTests: XCTestCase {
    func testVersion3StoreUpgradesWithStatementLinesKept() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MigrationV4-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "TallySeam.store")
        let lineId = UUID(), statementId = UUID()

        // Write the store as builds 1.0 (28)–(33) did: schema 3.0.0.
        do {
            let schema = Schema(versionedSchema: TallySeamSchemaV3.self)
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(old)
            context.insert(TallySeamSchemaV3.StatementTransaction(id: lineId, statementId: statementId,
                                                                  transactionDate: Date(timeIntervalSince1970: 1_790_000_000),
                                                                  description: "SYNTHETIC SHOP", amountMinorUnits: 1_234, currencyCode: "USD",
                                                                  directionRaw: StatementDirection.moneyOut.rawValue))
            try context.save()
        }

        let updated = try PersistenceService(storeURL: url)
        let lines = try updated.context.fetch(FetchDescriptor<StatementTransaction>())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.id, lineId); XCTAssertEqual(lines.first?.amountMinorUnits, 1_234)
        XCTAssertNil(lines.first?.runningBalance)
        lines.first?.runningBalance = 50_000
        try updated.context.save()
        let reopened = try PersistenceService(storeURL: url)
        XCTAssertEqual(try reopened.context.fetch(FetchDescriptor<StatementTransaction>()).first?.runningBalance, 50_000)
    }

    func testSavedBankStatementKeepsRunningBalancesAndStatusNeedsAProvenBalance() throws {
        let persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        let bank = PaymentMethod(name: "Wells Fargo Debit", type: .debitCard)
        persistence.context.insert(bank)
        try persistence.context.save()
        let repo = StatementRepository(context: persistence.context)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Denver")!
        let p = StatementImportService.preview(text: DocumentText(pages: [DocumentPage(index: 0, lines: StatementFixtures.bankLines, source: .plainText)]),
                                               format: .text, defaultCurrency: "USD", calendar: cal)
        let s = try repo.saveStatement(p, filename: "bank.pdf", fingerprint: "bank", paymentMethodId: bank.id, config: ReconciliationConfig(), calendar: cal)
        let lines = try repo.fetchLines(statementId: s.id)
        XCTAssertEqual(lines.first?.runningBalance, 350_000)
        for l in lines { try repo.skip(lineId: l.id) }
        XCTAssertEqual(s.reconciliationStatus, .incomplete, "one line couldn't be read, so the balance isn't proven")
        XCTAssertEqual(try repo.balanceReport(statementId: s.id).verdict, .notEnoughInformation)
    }
}
