import Foundation
import SwiftData
import XCTest
@testable import TallySeam

/// Counting a transaction in another month (early salary) and quick account setup. Synthetic data only.
final class CountedMonthTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }
    private func month(_ y: Int, _ m: Int) -> DateRange { cal.monthRange(containing: date(y, m, 15)) }
    private var finance: FinanceCalculationService { FinanceCalculationService(calendar: cal) }

    func testEarlySalaryCountsInTheMonthItIsFor() {
        let salary = TransactionRecord(transactionDate: date(2026, 10, 29), amountMinorUnits: 500_000, currencyCode: "USD",
                                       title: "Salary", transactionType: .income, countedMonth: 202_611)
        let octoberRent = TransactionRecord(transactionDate: date(2026, 10, 1), amountMinorUnits: 200_000, currencyCode: "USD",
                                            title: "Rent", transactionType: .expense)
        let records = [salary, octoberRent]
        XCTAssertEqual(finance.summary(of: records, in: month(2026, 10), currencyCode: "USD").incomeMinorUnits, 0)
        XCTAssertEqual(finance.summary(of: records, in: month(2026, 10), currencyCode: "USD").expenseMinorUnits, 200_000)
        XCTAssertEqual(finance.summary(of: records, in: month(2026, 11), currencyCode: "USD").incomeMinorUnits, 500_000)
        let flows = finance.monthlyFlows(records, endingWith: date(2026, 11, 15), count: 2, currencyCode: "USD")
        XCTAssertEqual(flows.map(\.incomeMinorUnits), [0, 500_000])
    }

    func testReportingDate() {
        var r = TransactionRecord(transactionDate: date(2026, 10, 29), amountMinorUnits: 1, title: "x", transactionType: .income)
        XCTAssertEqual(r.reportingDate(in: cal), r.transactionDate)
        XCTAssertFalse(r.isCountedInOtherMonth(calendar: cal))
        r.countedMonth = 202_610   // its own month: no change
        XCTAssertEqual(r.reportingDate(in: cal), r.transactionDate)
        r.countedMonth = 202_611
        XCTAssertEqual(r.reportingDate(in: cal), date(2026, 11, 1, hour: 12))
        XCTAssertTrue(r.isCountedInOtherMonth(calendar: cal))
        XCTAssertEqual(CountedMonth.offset(of: r, calendar: cal), 1)
        r.countedMonth = 202_613   // invalid month: ignored
        XCTAssertEqual(r.reportingDate(in: cal), r.transactionDate)
        r.transactionDate = date(2026, 12, 30); r.countedMonth = 202_701   // across a year end
        XCTAssertEqual(r.reportingDate(in: cal), date(2027, 1, 1, hour: 12))
    }

    func testExpenseCountedInNextMonthMovesBudgetAndDailySpending() {
        let rent = TransactionRecord(transactionDate: date(2026, 10, 30), amountMinorUnits: 180_000, currencyCode: "USD",
                                     title: "November rent", transactionType: .expense, countedMonth: 202_611)
        let budget = BudgetRecord(id: UUID(), categoryId: nil, amountMinorUnits: 200_000, currencyCode: "USD",
                                  effectiveStartMonth: date(2026, 1, 1), isActive: true)
        let calculator = BudgetCalculationService(finance: finance)
        XCTAssertEqual(calculator.progress(budgets: [budget], records: [rent], month: date(2026, 10, 15)).first?.spentMinorUnits, 0)
        XCTAssertEqual(calculator.progress(budgets: [budget], records: [rent], month: date(2026, 11, 15)).first?.spentMinorUnits, 180_000)
        let daily = finance.dailyExpenses([rent], in: month(2026, 11), currencyCode: "USD")
        XCTAssertEqual(daily.first?.minorUnits, 180_000, "shown on the 1st of the month it counts in")
        XCTAssertEqual(finance.dailyExpenses([rent], in: month(2026, 10), currencyCode: "USD").reduce(0) { $0 + $1.minorUnits }, 0)
    }

    func testDraftSavesAndReloadsTheOffset() throws {
        var d = TransactionDraft(currencyCode: "USD", date: date(2026, 10, 29))
        d.type = .income; d.title = "Salary"; d.amountText = "5000"; d.countedMonthOffset = 1
        let r = try d.makeRecord(categoryKinds: [:], calendar: cal)
        XCTAssertEqual(r.countedMonth, 202_611)

        d.countedMonthOffset = 0
        XCTAssertNil(try d.makeRecord(categoryKinds: [:], calendar: cal).countedMonth)
        d.countedMonthOffset = -1
        XCTAssertEqual(try d.makeRecord(categoryKinds: [:], calendar: cal).countedMonth, 202_609)
        d.countedMonthOffset = 5
        XCTAssertNil(try d.makeRecord(categoryKinds: [:], calendar: cal).countedMonth, "out-of-range offsets are never stored")

        d.countedMonthOffset = 1; d.type = .transfer
        XCTAssertNil(try d.makeRecord(categoryKinds: [:], calendar: cal).countedMonth, "transfers are never counted in a month")
    }

    func testEditingKeepsTheCountedMonth() throws {
        // TransactionDraft(editing:) reads the offset with the device calendar, so build the record with it too.
        let device = Calendar.current
        var d = TransactionDraft(currencyCode: "USD", date: device.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9))!)
        d.type = .income; d.title = "Salary"; d.amountText = "5000"; d.countedMonthOffset = 1
        let saved = try d.makeRecord(categoryKinds: [:], calendar: device)
        let edit = TransactionDraft(editing: saved)
        XCTAssertEqual(edit.countedMonthOffset, 1)
        XCTAssertEqual(try edit.makeRecord(categoryKinds: [:], calendar: device).countedMonth, saved.countedMonth)
        XCTAssertEqual(TransactionDraft.duplicating(saved).countedMonthOffset, 1, "a duplicated salary is also for the following month")
    }

    func testBackupJSONKeepsCountedMonthAndOldBackupsHaveNone() throws {
        let r = TransactionRecord(transactionDate: date(2026, 10, 29), amountMinorUnits: 1, title: "x", transactionType: .income, countedMonth: 202_611)
        let decoded = try JSONDecoder().decode(TransactionRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded.countedMonth, 202_611)
        let old = try BackupService.decode(Data(UpdateCompatibilityTests.frozenV1Backup.utf8))
        XCTAssertNil(old.transactions.first?.countedMonth)
    }

    func testCSVExportAndImportKeepCountedMonth() throws {
        let r = TransactionRecord(transactionDate: date(2026, 10, 29), amountMinorUnits: 500_000, currencyCode: "USD",
                                  title: "Salary", transactionType: .income, countedMonth: 202_611)
        let csv = CSVTransactionExporter.csv(records: [r], categoryNames: [:], paymentMethodNames: [:], calendar: cal)
        let table = try CSVParser.parse(csv)
        XCTAssertEqual(table.rows[1].last, "2026-11")
        let source = CSVImportSource(table: table, hasHeaderRow: true)
        let mapping = source.suggestedMapping(calendar: cal, locale: Locale(identifier: "en_US"))
        XCTAssertNotNil(mapping.countedMonth)
        let plan = CSVTransactionImporter.plan(source: source, mapping: mapping, options: CSVImportOptions(currencyCode: "USD"),
                                               categories: [], existing: [], suggester: HeuristicCategorySuggestionService(), calendar: cal)
        XCTAssertEqual(plan.recordsToImport(includeDuplicates: false).first?.countedMonth, 202_611)

        var bad = table
        bad.rows[1][bad.rows[1].count - 1] = "November"
        let badPlan = CSVTransactionImporter.plan(source: CSVImportSource(table: bad, hasHeaderRow: true), mapping: mapping,
                                                  options: CSVImportOptions(currencyCode: "USD"), categories: [], existing: [],
                                                  suggester: HeuristicCategorySuggestionService(), calendar: cal)
        XCTAssertEqual(badPlan.rows.first?.status, .invalid("Can't read the month \"November\""))
    }
}

/// The 1.0 → 2.0 store upgrade that adds `countedMonth`. Uses real on-disk stores.
@MainActor
final class SchemaV2MigrationTests: XCTestCase {
    func testVersion1StoreUpgradesWithoutLosingData() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MigrationV2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "TallySeam.store")
        let txId = UUID(), categoryId = UUID(), methodId = UUID()
        let when = Date(timeIntervalSince1970: 1_790_000_000)

        // Write the store exactly as app builds up to 1.0 (16) did: schema 1.0.0.
        do {
            let schema = Schema(versionedSchema: TallySeamSchemaV1.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            context.insert(TallySeamSchemaV1.MoneyTransaction(id: txId, transactionDate: when, amountMinorUnits: 4_780, currencyCode: "USD",
                                                            title: "Synthetic groceries", transactionTypeRaw: "expense", isRefund: true))
            context.insert(SpendingCategory(id: categoryId, name: "Hobbies", symbol: "star", colorIdentifier: "blue",
                                            kind: .expense, isSystemCategory: false, displayOrder: 99))
            context.insert(PaymentMethod(id: methodId, name: "Wells Fargo Debit", type: .debitCard, lastFourDigits: "1234"))
            context.insert(AppSettings())
            try context.save()
        }

        // Open it the way the updated app does.
        let updated = try PersistenceService(storeURL: url)
        let records = try TransactionRepository(context: updated.context).allRecords()
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.id, txId); XCTAssertEqual(r.amountMinorUnits, 4_780); XCTAssertEqual(r.title, "Synthetic groceries")
        XCTAssertEqual(r.transactionDate, when); XCTAssertTrue(r.isRefund); XCTAssertEqual(r.transactionType, .expense)
        XCTAssertNil(r.countedMonth)
        XCTAssertNotNil(try updated.context.fetch(FetchDescriptor<SpendingCategory>()).first { $0.id == categoryId })
        XCTAssertEqual(try updated.context.fetch(FetchDescriptor<PaymentMethod>()).first?.lastFourDigits, "1234")
        XCTAssertEqual(try updated.context.fetchCount(FetchDescriptor<AppSettings>()), 1)

        // The new field works on the upgraded store and survives another reopen.
        let t = try XCTUnwrap(TransactionRepository(context: updated.context).fetch(id: txId))
        t.countedMonth = 202_611
        try updated.context.save()
        let reopened = try PersistenceService(storeURL: url)
        XCTAssertEqual(try TransactionRepository(context: reopened.context).fetch(id: txId)?.countedMonth, 202_611)
    }
}

final class AccountSetupTests: XCTestCase {
    func testDefaultNames() {
        XCTAssertEqual(AccountPresets.defaultName("Wells Fargo", type: .debitCard), "Wells Fargo Debit")
        XCTAssertEqual(AccountPresets.defaultName("Capital One", type: .creditCard), "Capital One Credit")
        XCTAssertEqual(AccountPresets.defaultName("American Express", type: .creditCard), "American Express Credit")
        XCTAssertEqual(AccountPresets.defaultName("Apple Card", type: .creditCard), "Apple Card")
        XCTAssertEqual(AccountPresets.defaultName("Chase", type: .bankTransfer), "Chase Checking")
        XCTAssertEqual(AccountPresets.suggestions(for: .creditCard).first, "Capital One")
    }

    func testItemsToCreateTrimsAndSkipsDuplicates() throws {
        let items = [
            AccountSetupItem(name: " Cash ", type: .cash),
            AccountSetupItem(name: "Wells Fargo Debit", type: .debitCard, lastFour: "1234"),
            AccountSetupItem(name: "wells fargo debit", type: .debitCard),
            AccountSetupItem(name: "", type: .creditCard),
            AccountSetupItem(name: "Amex Credit", type: .creditCard),
        ]
        let result = try AccountSetup.itemsToCreate(items, existingNames: ["AMEX CREDIT"])
        XCTAssertEqual(result.map(\.name), ["Cash", "Wells Fargo Debit"])
        XCTAssertEqual(result[1].lastFour, "1234")
    }

    func testLastFourMustBeFourDigits() {
        for bad in ["123", "12345", "4111111111111111", "12a4"] {
            XCTAssertThrowsError(try AccountSetup.itemsToCreate([AccountSetupItem(name: "Card", type: .creditCard, lastFour: bad)],
                                                                existingNames: [])) {
                XCTAssertEqual($0 as? AccountSetupError, .invalidLastFour(name: "Card"), bad)
            }
        }
    }

    @MainActor
    func testCreatesCashWellsFargoCapitalOneAndAmex() throws {
        let persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        let repo = ReferenceDataRepository(context: persistence.context)
        let items = [
            AccountSetupItem(name: "Cash", type: .cash),
            AccountSetupItem(name: AccountPresets.defaultName("Wells Fargo", type: .debitCard), type: .debitCard, lastFour: "1111"),
            AccountSetupItem(name: AccountPresets.defaultName("Capital One", type: .creditCard), type: .creditCard),
            AccountSetupItem(name: AccountPresets.defaultName("American Express", type: .creditCard), type: .creditCard, lastFour: "2222"),
        ]
        XCTAssertEqual(try repo.createPaymentMethods(items, existingNames: []), 4)
        let methods = try persistence.context.fetch(FetchDescriptor<PaymentMethod>()).sorted { $0.name < $1.name }
        XCTAssertEqual(methods.map(\.name), ["American Express Credit", "Capital One Credit", "Cash", "Wells Fargo Debit"])
        XCTAssertEqual(methods.map(\.type), [.creditCard, .creditCard, .cash, .debitCard])
        XCTAssertEqual(methods.map(\.lastFourDigits), ["2222", nil, nil, "1111"])
        XCTAssertTrue(methods.allSatisfy(\.isActive))

        // Running setup again adds nothing.
        XCTAssertEqual(try repo.createPaymentMethods(items, existingNames: methods.map(\.name)), 0)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<PaymentMethod>()), 4)
    }
}
