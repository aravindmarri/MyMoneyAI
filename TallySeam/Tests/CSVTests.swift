import Foundation
import SwiftData
import XCTest
@testable import TallySeam

/// CSV import and export. Synthetic data only; fixed calendar so results don't depend on the runner.
final class CSVParserTests: XCTestCase {
    func testQuotesEscapesNewlinesAndLineNumbers() throws {
        let text = "\u{FEFF}Date,Description,Amount\r\n2024-01-05,\"Coffee, large\",-4.50\r\n\r\n2024-01-06,\"Says \"\"hi\"\"\nsecond line\",10\n2024-01-07,Last,1"
        let t = try CSVParser.parse(text)
        XCTAssertEqual(t.delimiter, ",")
        XCTAssertEqual(t.rows, [
            ["Date", "Description", "Amount"],
            ["2024-01-05", "Coffee, large", "-4.50"],
            ["2024-01-06", "Says \"hi\"\nsecond line", "10"],
            ["2024-01-07", "Last", "1"],
        ])
        XCTAssertEqual(t.lineNumbers, [1, 2, 4, 6])
    }

    func testSemicolonAndTabDelimitersAreDetected() throws {
        XCTAssertEqual(try CSVParser.parse("Datum;Betrag\n05.01.2024;-4,50").rows, [["Datum", "Betrag"], ["05.01.2024", "-4,50"]])
        XCTAssertEqual(try CSVParser.parse("a\tb\n1\t2").delimiter, "\t")
        XCTAssertEqual(try CSVParser.parse("\"a;b\",c\n1,2").delimiter, ",", "delimiters inside quotes are ignored")
    }

    func testBrokenAndEmptyFilesAreRejected() {
        XCTAssertThrowsError(try CSVParser.parse("a,b\n1,\"open")) { XCTAssertEqual($0 as? CSVError, .unterminatedQuote(line: 2)) }
        XCTAssertThrowsError(try CSVParser.parse("\n\n")) { XCTAssertEqual($0 as? CSVError, .empty) }
        XCTAssertThrowsError(try CSVParser.decode(Data(count: CSVParser.maximumFileBytes + 1))) { XCTAssertEqual($0 as? CSVError, .tooLarge) }
    }

    func testWindows1252FallbackDecoding() throws {
        let data = Data([0x43, 0x61, 0x66, 0xE9]) // "Café" in Windows-1252, invalid UTF-8
        XCTAssertEqual(try CSVParser.decode(data), "Café")
    }

    func testWriterEscapesAndRoundTrips() throws {
        let rows = [["a", "b,c", "say \"x\""], ["multi\nline", "", "semi;colon"]]
        XCTAssertEqual(try CSVParser.parse(CSVWriter.write(rows)).rows, rows)
        XCTAssertEqual(CSVWriter.textCell("=SUM(A1)"), "'=SUM(A1)")
        XCTAssertEqual(CSVWriter.textCell("@cmd"), "'@cmd")
        XCTAssertEqual(CSVWriter.textCell("Groceries"), "Groceries")
    }
}

final class CSVValueParsingTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func ymd(_ d: Date?) -> String? {
        guard let d else { return nil }
        let c = cal.dateComponents([.year, .month, .day, .hour], from: d)
        return "\(c.year!)-\(c.month!)-\(c.day!)@\(c.hour!)"
    }

    func testDateOrders() {
        XCTAssertEqual(ymd(CSVDateParser.parse("2024-01-31", order: .yearMonthDay, calendar: cal)), "2024-1-31@12")
        XCTAssertEqual(ymd(CSVDateParser.parse("2024/01/31 13:45:00", order: .yearMonthDay, calendar: cal)), "2024-1-31@12")
        XCTAssertEqual(ymd(CSVDateParser.parse("2024-01-31T23:59:00Z", order: .yearMonthDay, calendar: cal)), "2024-1-31@12")
        XCTAssertEqual(ymd(CSVDateParser.parse("01/31/2024", order: .monthDayYear, calendar: cal)), "2024-1-31@12")
        XCTAssertEqual(ymd(CSVDateParser.parse("31.01.24", order: .dayMonthYear, calendar: cal)), "2024-1-31@12")
        XCTAssertNil(CSVDateParser.parse("01/31/2024", order: .dayMonthYear, calendar: cal))
        XCTAssertNil(CSVDateParser.parse("2023-02-29", order: .yearMonthDay, calendar: cal), "not a leap year")
        XCTAssertNil(CSVDateParser.parse("Coffee", order: .yearMonthDay, calendar: cal))
    }

    func testMonthNamesParseInAnyOrder() {
        for s in ["5 Jan 2024", "05-Jan-2024", "Jan 5, 2024", "January 5 2024", "2024 Jan 05", "5 jan 24"] {
            XCTAssertEqual(ymd(CSVDateParser.parse(s, order: .monthDayYear, calendar: cal)), "2024-1-5@12", s)
        }
        XCTAssertNil(CSVDateParser.parse("5 Foo 2024", order: .dayMonthYear, calendar: cal))
    }

    func testCandidateOrdersUseValuesThenRegion() {
        let ambiguous = ["01/02/2024", "03/04/2024"]
        XCTAssertEqual(CSVDateParser.candidateOrders(samples: ambiguous, calendar: cal, locale: Locale(identifier: "en_US")).first, .monthDayYear)
        XCTAssertEqual(CSVDateParser.candidateOrders(samples: ambiguous, calendar: cal, locale: Locale(identifier: "en_GB")).first, .dayMonthYear)
        XCTAssertEqual(CSVDateParser.candidateOrders(samples: ["01/02/2024", "25/02/2024"], calendar: cal, locale: Locale(identifier: "en_US")), [.dayMonthYear])
        XCTAssertEqual(CSVDateParser.candidateOrders(samples: ["2024-02-01", ""], calendar: cal, locale: Locale(identifier: "en_US")), [.yearMonthDay])
        XCTAssertEqual(CSVDateParser.candidateOrders(samples: ["hello"], calendar: cal, locale: Locale(identifier: "en_US")), [])
    }

    func testAmountFormats() {
        let cases: [(String, Int64?)] = [
            ("-12.50", -1_250), ("12.50", 1_250), ("+12.50", 1_250), ("(12.50)", -1_250), ("12.50-", -1_250),
            ("12.50 CR", 1_250), ("12.50 DR", -1_250), ("$1,234.56", 123_456), ("-$1,234.56", -123_456),
            ("USD -7", -700), ("1.234,56", 123_456), ("−3.00", -300), ("1 234,56", 123_456), ("0.00", 0),
            ("", nil), ("abc", nil), ("12-50", nil), ("1.234", 123_400),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(CSVAmountParser.parse(raw, currencyCode: "USD"), expected, raw)
        }
        XCTAssertEqual(CSVAmountParser.parse("-1200", currencyCode: "JPY"), -1_200)
        XCTAssertEqual(CSVAmountParser.parse("1.234", currencyCode: "KWD"), 1_234)
    }

    func testPlainAmountExport() {
        XCTAssertEqual(CSVTransactionExporter.plainAmount(123_405, currencyCode: "USD"), "1234.05")
        XCTAssertEqual(CSVTransactionExporter.plainAmount(5, currencyCode: "USD"), "0.05")
        XCTAssertEqual(CSVTransactionExporter.plainAmount(1_200, currencyCode: "JPY"), "1200")
        XCTAssertEqual(CSVTransactionExporter.plainAmount(1_234, currencyCode: "KWD"), "1.234")
    }
}

final class CSVImportPlanTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private let us = Locale(identifier: "en_US")
    private let groceries = CategoryOption(id: UUID(), name: "Groceries", kind: .expense)
    private let restaurants = CategoryOption(id: UUID(), name: "Restaurants", kind: .expense)
    private let salary = CategoryOption(id: UUID(), name: "Salary", kind: .income)
    private var categories: [CategoryOption] { [groceries, restaurants, salary] }
    private let suggester = HeuristicCategorySuggestionService()

    private func source(_ text: String) throws -> CSVImportSource {
        let t = try CSVParser.parse(text)
        return CSVImportSource(table: t, hasHeaderRow: CSVImportSource.looksLikeHeader(t.rows[0], calendar: cal))
    }

    private func plan(_ s: CSVImportSource, _ m: CSVColumnMapping, existing: [TransactionRecord] = [],
                      paymentMethod: UUID? = nil, currency: String = "USD") -> CSVImportPlan {
        CSVTransactionImporter.plan(source: s, mapping: m, options: CSVImportOptions(currencyCode: currency, paymentMethodId: paymentMethod),
                                    categories: categories, existing: existing, suggester: suggester, calendar: cal)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    func testSingleAmountColumnBankStatement() throws {
        let s = try source("""
        Transaction Date,Description,Amount,Balance
        01/31/2024,STARBUCKS #123,-4.50,995.50
        02/01/2024,ACME PAYROLL,2000.00,2995.50
        02/02/2024,Grocery Outlet,(25.10),2970.40
        """)
        XCTAssertTrue(s.hasHeaderRow)
        let m = s.suggestedMapping(calendar: cal, locale: us)
        XCTAssertEqual(m.date, 0); XCTAssertEqual(m.description, 1); XCTAssertEqual(m.amount, 2)
        XCTAssertEqual(m.amountMode, .single); XCTAssertEqual(m.dateOrder, .monthDayYear)

        let pm = UUID()
        let p = plan(s, m, paymentMethod: pm, currency: "USD")
        XCTAssertEqual(p.newCount, 3); XCTAssertEqual(p.invalidCount, 0)
        let r = p.recordsToImport(includeDuplicates: false)
        XCTAssertEqual(r.map(\.transactionType), [.expense, .income, .expense])
        XCTAssertEqual(r.map(\.amountMinorUnits), [450, 200_000, 2_510])
        XCTAssertEqual(r.map(\.title), ["STARBUCKS #123", "ACME PAYROLL", "Grocery Outlet"])
        XCTAssertTrue(r.allSatisfy { $0.source == .csvImport && $0.paymentMethodId == pm && $0.currencyCode == "USD" })
        XCTAssertEqual(r[0].categoryId, restaurants.id, "suggested from the merchant directory")
        XCTAssertEqual(r[2].categoryId, groceries.id, "suggested from a keyword")
        XCTAssertTrue(p.rows[0].categorySuggested)
        XCTAssertEqual(cal.component(.day, from: r[0].transactionDate), 31)
    }

    func testPositiveMeansSpentOption() throws {
        let s = try source("Date,Description,Amount\n2024-03-01,Card purchase,12.00\n2024-03-02,Payment received,-50.00")
        var m = s.suggestedMapping(calendar: cal, locale: us)
        m.negativeIsExpense = false
        XCTAssertEqual(plan(s, m).recordsToImport(includeDuplicates: false).map(\.transactionType), [.expense, .income])
    }

    func testDebitCreditColumns() throws {
        let s = try source("""
        Date,Details,Money Out,Money In
        05/01/2024,Rent,1200.00,
        06/01/2024,Refund,,15.00
        07/01/2024,Weird,5.00,5.00
        08/01/2024,Nothing,,
        09/01/2024,Bad,abc,
        """)
        let m = s.suggestedMapping(calendar: cal, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(m.amountMode, .debitCredit); XCTAssertEqual(m.debit, 2); XCTAssertEqual(m.credit, 3)
        XCTAssertEqual(m.dateOrder, .dayMonthYear)
        let p = plan(s, m)
        XCTAssertEqual(p.newCount, 2); XCTAssertEqual(p.invalidCount, 3)
        XCTAssertEqual(p.rows.map(\.line), [2, 3, 4, 5, 6])
        XCTAssertEqual(p.rows[2].status, .invalid("Has both a debit and a credit"))
        XCTAssertEqual(p.rows[3].status, .invalid("Amount is zero"))
        XCTAssertEqual(p.rows[4].status, .invalid("Can't read the debit \"abc\""))
        let r = p.recordsToImport(includeDuplicates: false)
        XCTAssertEqual(r.map(\.transactionType), [.expense, .income])
        XCTAssertEqual(r.map(\.amountMinorUnits), [120_000, 1_500])
        XCTAssertEqual(cal.component(.month, from: r[0].transactionDate), 1)
    }

    func testHeaderlessFileAndInvalidRows() throws {
        let s = try source("2024-01-05,Lunch,-9.99\nnot a date,Lunch,-1\n2024-01-06,,\n2024-01-07,Taxi,-12")
        XCTAssertFalse(s.hasHeaderRow)
        XCTAssertEqual(s.columns, ["Column 1", "Column 2", "Column 3"])
        let m = s.suggestedMapping(calendar: cal, locale: us)
        XCTAssertEqual(m.date, 0); XCTAssertEqual(m.amount, 2); XCTAssertEqual(m.description, 1)
        let p = plan(s, m)
        XCTAssertEqual(p.newCount, 2)
        XCTAssertEqual(p.rows[1].status, .invalid("Can't read the date \"not a date\""))
        XCTAssertEqual(p.rows[2].status, .invalid("No amount"))
    }

    func testCategoryColumnMatchesByNameAndKind() throws {
        let s = try source("Date,Description,Amount,Category\n2024-01-05,Thing,-5,groceries\n2024-01-06,Pay,100,Groceries\n2024-01-07,Other,-1,Unknown")
        let r = plan(s, s.suggestedMapping(calendar: cal, locale: us)).recordsToImport(includeDuplicates: false)
        XCTAssertEqual(r[0].categoryId, groceries.id)
        XCTAssertNil(r[1].categoryId, "an expense category is never put on income")
        XCTAssertNil(r[2].categoryId)
    }

    func testDuplicatesMatchOncePerExistingTransaction() throws {
        let existing = [
            TransactionRecord(transactionDate: day(2024, 1, 5, hour: 8), amountMinorUnits: 450, currencyCode: "USD",
                              merchant: "Starbucks", title: "Coffee", transactionType: .expense),
            TransactionRecord(transactionDate: day(2024, 1, 6), amountMinorUnits: 1_000, currencyCode: "USD",
                              title: "Bookshop", transactionType: .expense),
        ]
        let s = try source("""
        Date,Description,Amount
        2024-01-05,STARBUCKS 0042,-4.50
        2024-01-05,STARBUCKS 0042,-4.50
        2024-01-06,Hardware store,-10.00
        2024-01-06,Bookshop,10.00
        """)
        let p = plan(s, s.suggestedMapping(calendar: cal, locale: us), existing: existing)
        XCTAssertEqual(p.rows[0].status, .duplicate(existingId: existing[0].id))
        XCTAssertEqual(p.rows[1].status, .new, "only one coffee was already in the app")
        XCTAssertEqual(p.rows[2].status, .new, "different description")
        XCTAssertEqual(p.rows[3].status, .new, "income doesn't match an expense")
        XCTAssertEqual(p.duplicateCount, 1)
        XCTAssertEqual(p.recordsToImport(includeDuplicates: false).count, 3)
        XCTAssertEqual(p.recordsToImport(includeDuplicates: true).count, 4)
    }

    func testIncompleteMapping() {
        var m = CSVColumnMapping()
        XCTAssertFalse(m.isComplete)
        m.date = 0; m.amount = 1
        XCTAssertTrue(m.isComplete)
        m.amountMode = .debitCredit
        XCTAssertFalse(m.isComplete)
        m.credit = 2
        XCTAssertTrue(m.isComplete)
    }

    func testExportFormat() throws {
        let fuel = UUID()
        let records = [
            TransactionRecord(transactionDate: day(2024, 2, 1), amountMinorUnits: 4_210, currencyCode: "USD", merchant: "Shell",
                              title: "=HYPERLINK(1)", notes: "line1\nline2", transactionType: .expense, categoryId: groceries.id, paymentMethodId: fuel),
            TransactionRecord(transactionDate: day(2024, 1, 1), amountMinorUnits: 500, currencyCode: "USD",
                              title: "Returned", transactionType: .expense, isRefund: true),
            TransactionRecord(transactionDate: day(2024, 1, 2), amountMinorUnits: 300_000, currencyCode: "JPY",
                              title: "Pay", transactionType: .income),
            TransactionRecord(transactionDate: day(2024, 1, 3), amountMinorUnits: 10_000, currencyCode: "USD",
                              title: "Card repayment", transactionType: .transfer),
        ]
        let csv = CSVTransactionExporter.csv(records: records, categoryNames: [groceries.id: "Groceries"],
                                             paymentMethodNames: [fuel: "Visa"], calendar: cal)
        let rows = try CSVParser.parse(csv).rows
        XCTAssertEqual(rows[0], CSVTransactionExporter.header)
        XCTAssertEqual(rows.map { $0[0] }.dropFirst(), ["2024-01-01", "2024-01-02", "2024-01-03", "2024-02-01"], "oldest first")
        XCTAssertEqual(rows[1], ["2024-01-01", "Expense", "Yes", "Returned", "", "", "", "5.00", "5.00", "USD", "", "Manual", ""])
        XCTAssertEqual(rows[2][7...9], ["300000", "300000", "JPY"])
        XCTAssertEqual(rows[3][8], "100.00", "transfers are not signed")
        XCTAssertEqual(rows[4], ["2024-02-01", "Expense", "", "'=HYPERLINK(1)", "Shell", "Groceries", "Visa", "42.10", "-42.10", "USD", "line1\nline2", "Manual", ""])
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testExportThenImportRestoresEveryField() throws {
        let originals = [
            TransactionRecord(transactionDate: day(2024, 4, 10, hour: 23), amountMinorUnits: 1_999, currencyCode: "USD", merchant: "Trader Joe's",
                              title: "Weekly shop", notes: "Synthetic, \"quoted\"", transactionType: .expense, categoryId: groceries.id),
            TransactionRecord(transactionDate: day(2024, 4, 11, hour: 0), amountMinorUnits: 250_000, currencyCode: "USD",
                              title: "Salary", transactionType: .income, categoryId: salary.id),
            TransactionRecord(transactionDate: day(2024, 4, 12), amountMinorUnits: 700, currencyCode: "USD",
                              title: "Returned shirt", transactionType: .expense, isRefund: true),
            TransactionRecord(transactionDate: day(2024, 4, 13), amountMinorUnits: 50_000, currencyCode: "USD",
                              title: "Card repayment", transactionType: .transfer),
        ]
        let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        let csv = CSVTransactionExporter.csv(records: originals, categoryNames: names, paymentMethodNames: [:], calendar: cal)
        let s = try source(csv)
        let m = s.suggestedMapping(calendar: cal, locale: us)
        XCTAssertNotNil(m.type); XCTAssertNotNil(m.refund); XCTAssertNotNil(m.merchant); XCTAssertNotNil(m.category)
        XCTAssertEqual(m.dateOrder, .yearMonthDay)

        let imported = plan(s, m).recordsToImport(includeDuplicates: false)
        XCTAssertEqual(imported.count, originals.count)
        for (a, b) in zip(originals, imported) {
            XCTAssertTrue(cal.isDate(a.transactionDate, inSameDayAs: b.transactionDate), a.title)
            XCTAssertEqual(a.transactionType, b.transactionType, a.title)
            XCTAssertEqual(a.amountMinorUnits, b.amountMinorUnits, a.title)
            XCTAssertEqual(a.title, b.title); XCTAssertEqual(a.merchant, b.merchant); XCTAssertEqual(a.notes, b.notes)
            XCTAssertEqual(a.categoryId, b.categoryId, a.title); XCTAssertEqual(a.isRefund, b.isRefund, a.title)
        }

        // Importing the same file again adds nothing.
        let again = plan(s, m, existing: originals)
        XCTAssertEqual(again.duplicateCount, originals.count)
        XCTAssertEqual(again.recordsToImport(includeDuplicates: false), [])
    }

    func testUnknownTransactionSourceDecodesAsManual() throws {
        let json = Data(#"["csvImport","receiptOCR","somethingNew"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([TransactionSource].self, from: json), [.csvImport, .receiptOCR, .manual])
    }
}

@MainActor
final class CSVImportStorageTests: XCTestCase {
    func testImportedTransactionsAreSavedAndCounted() throws {
        let persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        let repo = TransactionRepository(context: persistence.context)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!

        let t = try CSVParser.parse("Date,Description,Amount\n2024-05-01,Lunch,-10.00\n2024-05-02,Pay,500.00\n2024-05-03,Lunch,-10.00")
        let s = CSVImportSource(table: t, hasHeaderRow: true)
        let m = s.suggestedMapping(calendar: cal, locale: Locale(identifier: "en_US"))
        let options = CSVImportOptions(currencyCode: "USD")
        let first = CSVTransactionImporter.plan(source: s, mapping: m, options: options, categories: [], existing: try repo.allRecords(),
                                                suggester: HeuristicCategorySuggestionService(), calendar: cal)
        XCTAssertEqual(try repo.insertImported(first.recordsToImport(includeDuplicates: false)), 3)

        let saved = try repo.allRecords()
        XCTAssertEqual(saved.count, 3)
        XCTAssertTrue(saved.allSatisfy { $0.source == .csvImport })
        let month = cal.monthRange(containing: cal.date(from: DateComponents(year: 2024, month: 5, day: 15))!)
        let summary = FinanceCalculationService().summary(of: saved, in: month, currencyCode: "USD")
        XCTAssertEqual(summary.incomeMinorUnits, 50_000)
        XCTAssertEqual(summary.expenseMinorUnits, 2_000)

        let second = CSVTransactionImporter.plan(source: s, mapping: m, options: options, categories: [], existing: saved,
                                                 suggester: HeuristicCategorySuggestionService(), calendar: cal)
        XCTAssertEqual(second.duplicateCount, 3, "re-importing the same statement adds nothing")
    }
}
