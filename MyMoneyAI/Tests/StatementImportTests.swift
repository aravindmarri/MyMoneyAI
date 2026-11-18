import Foundation
import CoreGraphics
import PDFKit
import UIKit
import XCTest
@testable import MyMoneyAI

/// Synthetic statements, generated in code. No real bank or card documents are used anywhere.
enum StatementFixtures {
    static let bankLines = [
        "Wells Fargo Everyday Checking",
        "Account number: 1234567890125678",
        "Statement period 10/01/2026 - 10/31/2026",
        "Beginning balance on 10/1 $1,000.00",
        "Deposits and other additions 2,500.00",
        "Withdrawals and other subtractions -1,394.99",
        "Ending balance on 10/31 $2,105.01",
        "Transaction history",
        "Date Description Deposits Withdrawals Balance",
        "Deposits",
        "10/01 ACME PAYROLL DIRECT DEP 2,500.00 3,500.00",
        "Withdrawals",
        "10/03 WAL-MART STORE #2456 85.49 3,414.51",
        "SEATTLE WA",
        "10/05 PURCHASE AUTHORIZED ON 10/04 STARBUCKS",
        "STORE 1234 SEATTLE WA 4.50 3,410.01",
        "10/10 CHASE CREDIT CRD AUTOPAY 1,200.00 2,210.01",
        "10/12 ATM WITHDRAWAL 100.00 2,110.01",
        "10/15 CHECK 1043",
        "10/31 MONTHLY SERVICE FEE 5.00 2,105.01",
        "10/31 Ending balance 2,105.01",
        "Total withdrawals 1,394.99",
    ]

    static let cardLines = [
        "Capital One",
        "Quicksilver Card ending in 4321",
        "Opening/Closing Date 11/12/2026 - 12/11/2026",
        "Previous Balance $500.00",
        "Payments and Credits -$500.00",
        "Purchases +$240.40",
        "Fees Charged $0.00",
        "Interest Charged $3.10",
        "New Balance $243.50",
        "Minimum Payment Due $25.00",
        "Payment Due Date 01/05/2027",
        "Payments, Credits and Adjustments",
        "11/20 11/21 CAPITAL ONE AUTOPAY PYMT -$500.00",
        "Purchases",
        "11/14 11/15 WM SUPERCENTER #1234 $85.49",
        "12/10 12/11 AMAZON.COM*AB12CD SEATTLE WA $154.91",
        "Interest Charged",
        "12/11 12/11 INTEREST CHARGE ON PURCHASES $3.10",
    ]

    /// A PDF with real (selectable) text, one string per line.
    static func searchablePDF(pages: [[String]], password: String? = nil) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        if let password {
            format.documentInfo = [kCGPDFContextUserPassword as String: password, kCGPDFContextOwnerPassword as String: password]
        }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
        let font = UIFont(name: "Courier", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        return renderer.pdfData { ctx in
            for lines in pages {
                ctx.beginPage()
                for (i, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 36, y: 36 + CGFloat(i) * 16), withAttributes: [.font: font])
                }
            }
        }
    }

    /// A PDF page that is only a picture of text, like a scanned statement.
    static func scannedPDF(lines: [String]) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 612, height: 792)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 36, y: 36 + CGFloat(i) * 18), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
            }
        }
        return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { ctx in
            ctx.beginPage()
            image.draw(in: CGRect(x: 0, y: 0, width: 612, height: 792))
        }
    }
}

/// Stands in for Vision so the scanned-PDF path is tested deterministically.
struct FixedTextRecognizer: ReceiptTextRecognizing {
    var lines: [String]
    func recognizeText(in image: CGImage) async throws -> [String] { lines }
}

final class DocumentReadingTests: XCTestCase {
    func testFormatDetection() {
        XCTAssertEqual(DocumentFormatDetector.detect(filename: "x.bin", data: Data("%PDF-1.7".utf8)), .pdf)
        XCTAssertEqual(DocumentFormatDetector.detect(filename: "x", data: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])), .image)
        XCTAssertEqual(DocumentFormatDetector.detect(filename: "export", data: Data("Date,Description,Amount\n".utf8)), .csv)
        XCTAssertEqual(DocumentFormatDetector.detect(filename: "notes.txt", data: Data("hello".utf8)), .text)
        XCTAssertEqual(DocumentFormatDetector.detect(filename: "bank.ofx", data: Data("OFXHEADER:100".utf8)), .ofx)
        XCTAssertEqual(DocumentFormatDetector.detect(filename: "bank.qfx", data: Data("OFXHEADER:100".utf8)), .qfx)
        XCTAssertEqual(DocumentFormatDetector.detect(filename: "sheet.xlsx", data: Data([0x50, 0x4B, 3, 4])), .xlsx)
        XCTAssertEqual(DocumentFormatDetector.detect(filename: "blob", data: Data([0xFF, 0xFE, 0x00, 0xD8, 0x01])), .unknown)
        XCTAssertFalse(DocumentFormat.ofx.isSupported)
    }

    func testFingerprintIsStable() {
        let a = DocumentFingerprint.sha256(Data("statement".utf8))
        XCTAssertEqual(a, DocumentFingerprint.sha256(Data("statement".utf8)))
        XCTAssertNotEqual(a, DocumentFingerprint.sha256(Data("statement!".utf8)))
        XCTAssertEqual(a.count, 64)
    }

    func testSearchableMultiPagePDF() async throws {
        let data = StatementFixtures.searchablePDF(pages: [Array(StatementFixtures.bankLines.prefix(10)), Array(StatementFixtures.bankLines.dropFirst(10))])
        let text = try await PDFStatementReader(recognizer: FixedTextRecognizer(lines: [])).read(data, password: nil, progress: nil)
        XCTAssertEqual(text.pages.count, 2)
        XCTAssertTrue(text.pages.allSatisfy { $0.source == .embeddedText })
        XCTAssertFalse(text.usedOCR)
        XCTAssertTrue(text.pages[0].lines.contains { $0.contains("Wells Fargo") })
        XCTAssertTrue(text.pages[1].lines.contains { $0.contains("WAL-MART STORE #2456") })
    }

    func testScannedPDFIsReadWithOCR() async throws {
        let data = StatementFixtures.scannedPDF(lines: ["Some scanned text"])
        let reader = PDFStatementReader(recognizer: FixedTextRecognizer(lines: ["10/03 COFFEE 4.50", "  "]))
        let text = try await reader.read(data, password: nil, progress: nil)
        XCTAssertEqual(text.pages.first?.source, .ocr)
        XCTAssertEqual(text.pages.first?.lines, ["10/03 COFFEE 4.50"])
        XCTAssertTrue(text.usedOCR)
    }

    func testPasswordProtectedPDF() async throws {
        let data = StatementFixtures.searchablePDF(pages: [["Synthetic protected statement text"]], password: "synthetic-pass")
        let reader = PDFStatementReader(recognizer: FixedTextRecognizer(lines: []))
        do { _ = try await reader.read(data, password: nil, progress: nil); XCTFail("expected a password prompt") }
        catch { XCTAssertEqual(error as? DocumentReadError, .passwordRequired) }
        do { _ = try await reader.read(data, password: "wrong", progress: nil); XCTFail("expected wrong password") }
        catch { XCTAssertEqual(error as? DocumentReadError, .wrongPassword) }
        let text = try await reader.read(data, password: "synthetic-pass", progress: nil)
        XCTAssertTrue(text.allLines.joined().contains("protected statement"))
    }

    func testInvalidFiles() async {
        let reader = PDFStatementReader(recognizer: FixedTextRecognizer(lines: []))
        do { _ = try await reader.read(Data("%PDF-not really".utf8), password: nil, progress: nil); XCTFail() }
        catch {
            let e = error as? DocumentReadError
            XCTAssertTrue(e == .unreadable || e == .noText, "\(error)")
        }
        do { _ = try await PlainTextDocumentReader().read(Data("  \n \n".utf8), password: nil, progress: nil); XCTFail() }
        catch { XCTAssertEqual(error as? DocumentReadError, .noText) }
        // A blank scanned page where OCR finds nothing.
        do { _ = try await reader.read(StatementFixtures.scannedPDF(lines: []), password: nil, progress: nil); XCTFail() }
        catch { XCTAssertEqual(error as? DocumentReadError, .noText) }
    }

    func testServiceRoutesEachFormat() async throws {
        let service = StatementImportService(recognizer: FixedTextRecognizer(lines: []))
        let csv = await service.read(filename: "export.csv", data: Data("Date,Description,Amount\n2026-10-01,Coffee,-4.50".utf8), defaultCurrency: "USD")
        guard case .csv(let table) = csv.content else { return XCTFail("csv") }
        XCTAssertEqual(table.rows.count, 2)

        let png = await service.read(filename: "shot.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]), defaultCurrency: "USD")
        guard case .image = png.content else { return XCTFail("image") }

        let ofx = await service.read(filename: "bank.ofx", data: Data("OFXHEADER:100".utf8), defaultCurrency: "USD")
        guard case .failed(let reason) = ofx.content else { return XCTFail("ofx") }
        XCTAssertTrue(reason.contains("OFX"))

        let locked = await service.read(filename: "s.pdf", data: StatementFixtures.searchablePDF(pages: [["x"]], password: "p"), defaultCurrency: "USD")
        guard case .needsPassword = locked.content else { return XCTFail("locked") }

        let pdf = await service.read(filename: "bank.pdf", data: StatementFixtures.searchablePDF(pages: [StatementFixtures.bankLines]), defaultCurrency: "USD")
        guard case .statement(let p) = pdf.content else { return XCTFail("statement: \(pdf.content)") }
        XCTAssertEqual(p.kind, .bankStatement)
        XCTAssertEqual(p.parse.lines.count, 6)
        XCTAssertEqual(pdf.fingerprint.count, 64)
    }
}

final class StatementParsingTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
    private func preview(_ lines: [String]) -> StatementPreview {
        StatementImportService.preview(text: DocumentText(pages: [DocumentPage(index: 0, lines: lines, source: .plainText)]),
                                       format: .text, defaultCurrency: "USD", calendar: cal, now: day(2026, 11, 18))
    }

    func testClassification() {
        XCTAssertEqual(preview(StatementFixtures.bankLines).kind, .bankStatement)
        XCTAssertEqual(preview(StatementFixtures.cardLines).kind, .creditCardStatement)
        XCTAssertEqual(DocumentClassifier.classify(lines: ["CORNER MARKET", "Milk 3.99", "Subtotal 3.99", "Sales tax 0.30", "Cashier: 4"], format: .image).kind, .receipt)
        XCTAssertEqual(DocumentClassifier.classify(lines: ["INVOICE", "Invoice number 1001", "Bill to: Synthetic Co", "Amount due 120.00", "Terms: Net 30"], format: .pdf).kind, .invoice)
        XCTAssertEqual(DocumentClassifier.classify(lines: ["Payment confirmation", "Confirmation number ABC123", "You paid $50.00"], format: .pdf).kind, .paymentConfirmation)
        XCTAssertEqual(DocumentClassifier.classify(lines: ["Hello world", "Nothing financial here"], format: .text).kind, .unknown)
        XCTAssertEqual(DocumentClassifier.classify(lines: [], format: .csv).kind, .transactionExport)
        XCTAssertFalse(preview(StatementFixtures.cardLines).classification.reasons.isEmpty)
    }

    func testBankHeader() {
        let h = preview(StatementFixtures.bankLines).header
        XCTAssertEqual(h.institution, "Wells Fargo")
        XCTAssertEqual(h.accountType, .checking)
        XCTAssertEqual(h.lastFour, "5678", "a full account number is cut to its last four digits")
        XCTAssertEqual(h.periodStart, day(2026, 10, 1)); XCTAssertEqual(h.periodEnd, day(2026, 10, 31))
        XCTAssertEqual(h.openingBalance, 100_000); XCTAssertEqual(h.closingBalance, 210_501)
        XCTAssertEqual(h.totalDeposits, 250_000); XCTAssertEqual(h.totalWithdrawals, -139_499)
        XCTAssertEqual(h.currencyCode, "USD")
    }

    func testBankTransactions() {
        let p = preview(StatementFixtures.bankLines).parse
        XCTAssertEqual(p.lines.map(\.amountMinorUnits), [250_000, 8_549, 450, 120_000, 10_000, 500])
        XCTAssertEqual(p.lines.map(\.direction), [.moneyIn, .moneyOut, .moneyOut, .moneyOut, .moneyOut, .moneyOut])
        XCTAssertEqual(p.lines.map(\.kind), [.deposit, .withdrawal, .withdrawal, .cardPayment, .cashWithdrawal, .fee])
        XCTAssertEqual(p.lines[1].description, "WAL-MART STORE #2456 SEATTLE WA", "wrapped description is joined")
        XCTAssertEqual(p.lines[2].description, "PURCHASE AUTHORIZED ON 10/04 STARBUCKS STORE 1234 SEATTLE WA")
        XCTAssertEqual(p.lines[2].runningBalance, 341_001, "the balance column is not taken as the amount")
        XCTAssertEqual(p.lines[0].runningBalance, 350_000)
        XCTAssertEqual(p.lines[1].transactionDate, day(2026, 10, 3))
        XCTAssertEqual(p.totalIn, 250_000); XCTAssertEqual(p.totalOut, 139_499)
        XCTAssertEqual(p.issues.count, 1, "the check with no amount is kept as an issue, not dropped")
        XCTAssertEqual(p.issues.first?.text, "10/15 CHECK 1043")
        XCTAssertEqual(p.issues.first?.line, 19)
    }

    func testCardStatement() {
        let pv = preview(StatementFixtures.cardLines)
        let h = pv.header
        XCTAssertEqual(h.institution, "Capital One"); XCTAssertEqual(h.accountType, .creditCard); XCTAssertEqual(h.lastFour, "4321")
        XCTAssertEqual(h.periodStart, day(2026, 11, 12)); XCTAssertEqual(h.periodEnd, day(2026, 12, 11))
        XCTAssertEqual(h.openingBalance, 50_000); XCTAssertEqual(h.closingBalance, 24_350)
        XCTAssertEqual(h.totalPaymentsAndCredits, -50_000); XCTAssertEqual(h.totalPurchases, 24_040)
        XCTAssertEqual(h.totalFees, 0); XCTAssertEqual(h.totalInterest, 310); XCTAssertEqual(h.minimumPayment, 2_500)
        XCTAssertEqual(h.paymentDueDate, day(2027, 1, 5))

        let p = pv.parse
        XCTAssertEqual(p.lines.map(\.kind), [.cardPayment, .purchase, .purchase, .interest])
        XCTAssertEqual(p.lines.map(\.direction), [.moneyIn, .moneyOut, .moneyOut, .moneyOut])
        XCTAssertEqual(p.lines.map(\.amountMinorUnits), [50_000, 8_549, 15_491, 310])
        XCTAssertEqual(p.lines[0].transactionDate, day(2026, 11, 20)); XCTAssertEqual(p.lines[0].postingDate, day(2026, 11, 21))
        XCTAssertEqual(p.lines[1].description, "WM SUPERCENTER #1234")
        XCTAssertEqual(p.totalOut, 24_350); XCTAssertEqual(p.totalIn, 50_000)
        XCTAssertTrue(p.issues.isEmpty)
    }

    func testYearIsInferredAcrossDecemberAndJanuary() {
        let lines = ["Statement period 12/15/2026 - 01/14/2027", "12/20 COFFEE SHOP 4.00", "01/03 BOOKSTORE 12.00", "Feb 2 FUTURE 1.00"]
        let p = preview(lines).parse
        XCTAssertEqual(p.lines[0].transactionDate, day(2026, 12, 20))
        XCTAssertEqual(p.lines[1].transactionDate, day(2027, 1, 3))
        XCTAssertEqual(p.lines[2].transactionDate, day(2027, 2, 2), "month-name dates parse too")
        XCTAssertEqual(StatementLineParser.resolve(.init(month: 12, day: 31, year: nil), periodEnd: day(2027, 1, 14), calendar: cal), day(2026, 12, 31))
    }

    func testSignsMarkersPendingAndBadDates() {
        let p = preview(["10/02 COFFEE -4.50", "10/03 MYSTERY 10.00", "10/04 RETURN 10.00 CR", "10/05 THING 7.00 DR",
                         "10/30 PENDING UBER TRIP 12.00", "02/30 IMPOSSIBLE DATE 1.00", "(12.00) not a dated line"]).parse
        XCTAssertEqual(p.lines.map(\.direction), [.moneyOut, .moneyOut, .moneyIn, .moneyOut, .moneyOut])
        XCTAssertEqual(p.lines[0].confidence, .high)
        XCTAssertEqual(p.lines[1].confidence, .low, "a bank amount with no sign or section is flagged")
        XCTAssertNotNil(p.lines[1].note)
        XCTAssertTrue(p.lines[4].isPending)
        XCTAssertEqual(p.issues.map(\.reason), ["The date isn't a real calendar date"])
    }

    func testMoneyTokens() {
        let t = MoneyText.tokens(in: "10/05 STORE #2456 ON 10/04 $1,234.56 (12.00) 8.10- 3.00 CR 99")
        XCTAssertEqual(t.map(\.value), [123_456, -1_200, -810, 300])
        XCTAssertTrue(t[3].isCreditMarked)
        XCTAssertEqual(StatementHeaderExtractor.lastFour(in: ["Card number XXXX XXXX XXXX 9876"]), "9876")
        XCTAssertEqual(StatementHeaderExtractor.lastFour(in: ["Account ending in 0042"]), "0042")
        XCTAssertNil(StatementHeaderExtractor.lastFour(in: ["No numbers here"]))
    }

    func testReparseKeepsHandEditedLines() {
        var pv = preview(StatementFixtures.cardLines)
        var edited = pv.parse.lines[1]
        edited.description = "Walmart groceries"; edited.isEdited = true
        pv.parse.lines[1] = edited
        let again = StatementImportService.reparse(pv, calendar: cal, now: day(2026, 12, 20))
        XCTAssertEqual(again.parse.lines.count, 4)
        XCTAssertEqual(again.parse.lines[1].description, "Walmart groceries")
    }
}

final class CSVStatementColumnTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    func testBalanceAndPendingColumns() throws {
        let t = try CSVParser.parse("Date,Description,Amount,Running Balance,Status\n2026-10-01,Coffee,-4.50,95.50,Posted\n2026-10-02,Taxi,-12.00,83.50,Pending")
        let s = CSVImportSource(table: t, hasHeaderRow: true)
        let m = s.suggestedMapping(calendar: cal, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(m.amount, 2); XCTAssertEqual(m.balance, 3); XCTAssertEqual(m.status, 4)
        let plan = CSVTransactionImporter.plan(source: s, mapping: m, options: CSVImportOptions(currencyCode: "USD"), categories: [],
                                               existing: [], suggester: HeuristicCategorySuggestionService(), calendar: cal)
        XCTAssertEqual(plan.pendingCount, 1)
        XCTAssertEqual(plan.recordsToImport(includeDuplicates: false).map(\.title), ["Coffee"], "pending rows are skipped by default")
        XCTAssertEqual(plan.recordsToImport(includeDuplicates: false, includePending: true).count, 2)
        XCTAssertEqual(plan.recordsToImport(includeDuplicates: false).first?.amountMinorUnits, 450, "the balance is never used as the amount")
    }

    func testMappingIsRememberedPerLayout() throws {
        let suite = "CSVMappingStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CSVMappingStore(defaults: defaults)
        let s = CSVImportSource(table: try CSVParser.parse("Posted,Details,Value\n2026-10-01,Coffee,4.50"), hasHeaderRow: true)
        XCTAssertNil(store.mapping(for: s))
        var m = CSVColumnMapping(); m.date = 0; m.description = 1; m.amount = 2; m.negativeIsExpense = false
        store.save(m, for: s)
        XCTAssertEqual(store.mapping(for: s), m)
        let sameLayout = CSVImportSource(table: try CSVParser.parse("posted,details,value\n2026-11-01,Tea,3.00"), hasHeaderRow: true)
        XCTAssertEqual(store.mapping(for: sameLayout), m, "header case doesn't matter")
        let other = CSVImportSource(table: try CSVParser.parse("Date,Amount\n2026-10-01,1"), hasHeaderRow: true)
        XCTAssertNil(store.mapping(for: other))
        XCTAssertNil(CSVMappingStore.signature(CSVImportSource(table: try CSVParser.parse("2026-10-01,1"), hasHeaderRow: false)))
    }
}
