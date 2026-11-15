import Foundation
import SwiftData
import Testing
import XCTest
@testable import MyMoneyAI

private func utcCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12, calendar: Calendar = utcCalendar()) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
}

// MARK: - Schedule and due status

@Suite struct BillScheduleTests {
    let cal = utcCalendar()

    @Test func dueStatusByCalendarDay() {
        let now = day(2024, 3, 15, hour: 23)
        #expect(BillSchedule.status(dueDate: day(2024, 3, 13, hour: 1), isActive: true, now: now, calendar: cal) == .overdue(days: 2))
        #expect(BillSchedule.status(dueDate: day(2024, 3, 15, hour: 0), isActive: true, now: now, calendar: cal) == .dueToday)
        #expect(BillSchedule.status(dueDate: day(2024, 3, 16, hour: 0), isActive: true, now: now, calendar: cal) == .dueSoon(days: 1))
        #expect(BillSchedule.status(dueDate: day(2024, 3, 22), isActive: true, now: now, calendar: cal) == .dueSoon(days: 7))
        #expect(BillSchedule.status(dueDate: day(2024, 3, 23), isActive: true, now: now, calendar: cal) == .upcoming(days: 8))
        #expect(BillSchedule.status(dueDate: day(2024, 1, 1), isActive: false, now: now, calendar: cal) == .inactive)
        #expect(BillDueStatus.overdue(days: 1).label == "1 day overdue")
        #expect(BillDueStatus.dueSoon(days: 1).label == "Due tomorrow")
    }

    @Test func weeklyCustomAndYearly() {
        #expect(BillSchedule.nextDueDate(after: day(2024, 12, 28), rule: .weekly, customIntervalDays: nil, calendar: cal) == day(2025, 1, 4))
        #expect(BillSchedule.nextDueDate(after: day(2024, 2, 20), rule: .custom, customIntervalDays: 10, calendar: cal) == day(2024, 3, 1))
        #expect(BillSchedule.nextDueDate(after: day(2024, 2, 20), rule: .custom, customIntervalDays: nil, calendar: cal) == nil)
        #expect(BillSchedule.nextDueDate(after: day(2024, 2, 20), rule: .custom, customIntervalDays: 0, calendar: cal) == nil)
        #expect(BillSchedule.nextDueDate(after: day(2024, 2, 29), rule: .yearly, customIntervalDays: nil, calendar: cal) == day(2025, 2, 28))
        #expect(BillSchedule.nextDueDate(after: day(2023, 2, 28), rule: .yearly, customIntervalDays: nil, calendar: cal) == day(2024, 2, 29))
    }

    @Test func monthlyKeepsDayAndEndOfMonth() {
        func next(_ d: Date) -> Date? { BillSchedule.nextDueDate(after: d, rule: .monthly, customIntervalDays: nil, calendar: cal) }
        #expect(next(day(2024, 1, 15)) == day(2024, 2, 15))
        #expect(next(day(2024, 12, 15)) == day(2025, 1, 15))
        // Last day of the month stays on the last day: no drift to the 29th.
        #expect(next(day(2024, 1, 31)) == day(2024, 2, 29))
        #expect(next(day(2024, 2, 29)) == day(2024, 3, 31))
        #expect(next(day(2024, 4, 30)) == day(2024, 5, 31))
        // A mid-month day is not moved to the end of the month.
        #expect(next(day(2024, 1, 30)) == day(2024, 2, 29))
        #expect(next(day(2024, 3, 30)) == day(2024, 4, 30))
    }

    @Test func billDraftValidation() {
        var d = BillDraft(currencyCode: "USD", nextDueDate: day(2024, 3, 1))
        #expect(d.validationErrors == [.missingTitle])
        d.title = "  Rent "
        #expect(d.validationErrors.isEmpty)
        #expect(d.expectedAmount == .some(nil), "Empty amount means it varies")
        d.amountText = "abc"
        #expect(d.validationErrors == [.invalidAmount])
        d.amountText = "0"
        #expect(d.validationErrors == [.invalidAmount])
        d.amountText = "1200.50"
        #expect(d.expectedAmount == .some(120_050))
        d.rule = .custom
        #expect(d.validationErrors == [.invalidInterval])
        d.customIntervalText = "14"
        #expect(d.validationErrors.isEmpty)
    }

    @Test func paymentCandidatesPreferExactAmountThenClosestDate() {
        let due = day(2024, 3, 10)
        let exactFar = TransactionRecord(transactionDate: day(2024, 3, 18), amountMinorUnits: 5_000, title: "Phone", transactionType: .expense)
        let otherNear = TransactionRecord(transactionDate: day(2024, 3, 10), amountMinorUnits: 4_999, title: "Phone", transactionType: .expense)
        let tooFar = TransactionRecord(transactionDate: day(2024, 3, 25), amountMinorUnits: 5_000, title: "Phone", transactionType: .expense)
        let linked = TransactionRecord(transactionDate: due, amountMinorUnits: 5_000, title: "x", transactionType: .expense, recurringBillId: UUID())
        let income = TransactionRecord(transactionDate: due, amountMinorUnits: 5_000, title: "x", transactionType: .income)
        let refund = TransactionRecord(transactionDate: due, amountMinorUnits: 5_000, title: "x", transactionType: .expense, isRefund: true)
        let euro = TransactionRecord(transactionDate: due, amountMinorUnits: 5_000, currencyCode: "EUR", title: "x", transactionType: .expense)
        let result = BillSchedule.paymentCandidates([otherNear, tooFar, linked, income, refund, euro, exactFar], dueDate: due,
                                                    expectedAmount: 5_000, currencyCode: "USD", calendar: cal)
        #expect(result.map(\.id) == [exactFar.id, otherNear.id])
    }
}

// MARK: - Budget progress

@Suite struct BudgetCalculationTests {
    let cal = utcCalendar()
    var service: BudgetCalculationService { BudgetCalculationService(finance: FinanceCalculationService(calendar: cal)) }
    let groceries = UUID()
    let fuel = UUID()

    func expense(_ amount: Int64, _ date: Date, category: UUID?, currency: String = "USD", refund: Bool = false) -> TransactionRecord {
        TransactionRecord(transactionDate: date, amountMinorUnits: amount, currencyCode: currency, title: "x",
                          transactionType: .expense, categoryId: category, isRefund: refund)
    }

    @Test func progressUsesMonthExpensesNetOfRefundsAndIgnoresTransfers() {
        let start = day(2024, 1, 1)
        let overall = BudgetRecord(categoryId: nil, amountMinorUnits: 100_000, effectiveStartMonth: start)
        let grocery = BudgetRecord(categoryId: groceries, amountMinorUnits: 40_000, effectiveStartMonth: start)
        let records = [
            expense(30_000, day(2024, 3, 1, hour: 0), category: groceries),
            expense(5_000, day(2024, 3, 20), category: groceries, refund: true),
            expense(20_000, day(2024, 3, 31, hour: 23), category: fuel),
            expense(99_999, day(2024, 4, 1, hour: 0), category: groceries),            // next month
            expense(99_999, day(2024, 3, 10), category: groceries, currency: "EUR"),   // other currency
            TransactionRecord(transactionDate: day(2024, 3, 5), amountMinorUnits: 77_777, title: "Card payment", transactionType: .transfer),
            TransactionRecord(transactionDate: day(2024, 3, 5), amountMinorUnits: 50_000, title: "Pay", transactionType: .income),
        ]
        let p = service.progress(budgets: [grocery, overall], records: records, month: day(2024, 3, 15))
        #expect(p.map(\.id) == [overall.id, grocery.id], "Overall first")
        #expect(p[0].spentMinorUnits == 45_000)
        #expect(p[0].remainingMinorUnits == 55_000)
        #expect(p[0].status == .onTrack)
        #expect(p[1].spentMinorUnits == 25_000)
    }

    @Test func statusThresholds() {
        let b = BudgetRecord(categoryId: nil, amountMinorUnits: 10_000, effectiveStartMonth: day(2024, 1, 1))
        #expect(BudgetProgress(budget: b, spentMinorUnits: 7_999).status == .onTrack)
        #expect(BudgetProgress(budget: b, spentMinorUnits: 8_000).status == .nearLimit)
        #expect(BudgetProgress(budget: b, spentMinorUnits: 10_000).status == .nearLimit)
        let over = BudgetProgress(budget: b, spentMinorUnits: 12_500)
        #expect(over.status == .over)
        #expect(over.remainingMinorUnits == -2_500)
        #expect(over.fraction == 1.25)
        #expect(BudgetProgress(budget: b, spentMinorUnits: -500).fraction == 0)
    }

    @Test func excludesInactiveFutureAndOtherCurrencyBudgets() {
        let active = BudgetRecord(categoryId: groceries, amountMinorUnits: 1, effectiveStartMonth: day(2024, 3, 20))
        let future = BudgetRecord(categoryId: fuel, amountMinorUnits: 1, effectiveStartMonth: day(2024, 4, 1))
        let paused = BudgetRecord(categoryId: nil, amountMinorUnits: 1, effectiveStartMonth: day(2024, 1, 1), isActive: false)
        let euro = BudgetRecord(categoryId: groceries, amountMinorUnits: 10_000, currencyCode: "EUR", effectiveStartMonth: day(2024, 1, 1))
        let records = [expense(3_000, day(2024, 3, 2), category: groceries), expense(900, day(2024, 3, 2), category: groceries, currency: "EUR")]
        let p = service.progress(budgets: [active, future, paused, euro], records: records, month: day(2024, 3, 1))
        #expect(Set(p.map(\.id)) == [active.id, euro.id], "Start month counts from the 1st; future and paused budgets excluded")
        #expect(p.first { $0.id == euro.id }?.spentMinorUnits == 900)
        #expect(p.first { $0.id == active.id }?.spentMinorUnits == 3_000)
    }

    @Test func budgetDraftAmount() {
        var d = BudgetDraft(currencyCode: "JPY")
        d.amountText = "5000"
        #expect(d.amountMinorUnits == 5_000)
        d.amountText = "-1"
        #expect(d.amountMinorUnits == nil)
    }
}

// MARK: - Repositories (in-memory SwiftData)

@MainActor
final class BillRepositoryTests: XCTestCase {
    private var persistence: PersistenceService!
    private var bills: BillRepository!
    private var budgets: BudgetRepository!
    private var transactions: TransactionRepository!
    private let cal = utcCalendar()

    override func setUp() async throws {
        persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        bills = BillRepository(context: persistence.context, calendar: cal)
        budgets = BudgetRepository(context: persistence.context, calendar: cal)
        transactions = TransactionRepository(context: persistence.context)
    }

    private func category(_ name: String) throws -> SpendingCategory {
        try XCTUnwrap(persistence.context.fetch(FetchDescriptor<SpendingCategory>()).first { $0.name == name })
    }

    private func makeBill(amount: String = "50.00", due: Date = day(2024, 3, 10)) throws -> RecurringBill {
        var d = BillDraft(currencyCode: "USD", nextDueDate: due)
        d.title = "Phone"; d.amountText = amount; d.categoryId = try category("Utilities").id
        return try bills.save(d)
    }

    func testSavingBillCreatesNoTransactionAndNoSpending() throws {
        let bill = try makeBill()
        XCTAssertEqual(bill.expectedAmountMinorUnits, 5_000)
        XCTAssertEqual(try transactions.allRecords().count, 0)
        let summary = FinanceCalculationService(calendar: cal).summary(of: try transactions.allRecords(),
                                                                         in: cal.monthRange(containing: day(2024, 3, 1)), currencyCode: "USD")
        XCTAssertEqual(summary.expenseMinorUnits, 0)
    }

    func testIncomeCategoryIsDroppedFromBill() throws {
        var d = BillDraft(currencyCode: "USD", nextDueDate: day(2024, 3, 10))
        d.title = "Odd"; d.categoryId = try category("Salary").id
        XCTAssertNil(try bills.save(d).categoryId)
    }

    func testMarkPaidCreatesOneLinkedExpenseAndAdvances() throws {
        let bill = try makeBill()
        let paid = try bills.markPaid(billId: bill.id, payment: .newTransaction(amountMinorUnits: 5_250, date: day(2024, 3, 9), paymentMethodId: nil))
        let all = try transactions.allRecords()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, paid.id)
        XCTAssertEqual(paid.transactionType, .expense)
        XCTAssertEqual(paid.amountMinorUnits, 5_250)
        XCTAssertEqual(paid.recurringBillId, bill.id)
        XCTAssertEqual(paid.categoryId, try category("Utilities").id)
        XCTAssertEqual(bill.nextDueDate, day(2024, 4, 10), "Advances from the due date, not the payment date")
        XCTAssertEqual(try bills.payments(billId: bill.id).map(\.id), [paid.id])
    }

    func testLinkingExistingExpenseDoesNotCreateAnother() throws {
        let bill = try makeBill()
        var draft = TransactionDraft(currencyCode: "USD", date: day(2024, 3, 11))
        draft.title = "Phone receipt"; draft.amountText = "50.00"
        let existing = try transactions.save(draft, categoryKinds: try ReferenceDataRepository(context: persistence.context).categoryKinds())

        try bills.markPaid(billId: bill.id, payment: .existingTransaction(id: existing.id))
        let all = try transactions.allRecords()
        XCTAssertEqual(all.count, 1, "No duplicate expense")
        XCTAssertEqual(all.first?.recurringBillId, bill.id)
        XCTAssertEqual(bill.nextDueDate, day(2024, 4, 10))

        // The same expense can't pay the bill again.
        XCTAssertThrowsError(try bills.markPaid(billId: bill.id, payment: .existingTransaction(id: existing.id))) {
            XCTAssertEqual($0 as? RepositoryError, .transactionAlreadyLinkedToBill)
        }
        XCTAssertEqual(bill.nextDueDate, day(2024, 4, 10), "A failed payment doesn't advance the bill")
    }

    func testLinkRejectsIncomeAndOtherCurrency() throws {
        let bill = try makeBill()
        let kinds = try ReferenceDataRepository(context: persistence.context).categoryKinds()
        var income = TransactionDraft(currencyCode: "USD", date: day(2024, 3, 10))
        income.type = .income; income.title = "Pay"; income.amountText = "50"
        let i = try transactions.save(income, categoryKinds: kinds)
        XCTAssertThrowsError(try bills.markPaid(billId: bill.id, payment: .existingTransaction(id: i.id))) {
            XCTAssertEqual($0 as? RepositoryError, .billPaymentMustBeExpense)
        }
        var euro = TransactionDraft(currencyCode: "EUR", date: day(2024, 3, 10))
        euro.title = "Phone"; euro.amountText = "50"
        let e = try transactions.save(euro, categoryKinds: kinds)
        XCTAssertThrowsError(try bills.markPaid(billId: bill.id, payment: .existingTransaction(id: e.id))) {
            XCTAssertEqual($0 as? RepositoryError, .billCurrencyMismatch)
        }
        XCTAssertEqual(bill.nextDueDate, day(2024, 3, 10))
    }

    func testSkipAndDeleteKeepPayments() throws {
        let bill = try makeBill()
        try bills.skipPeriod(billId: bill.id)
        XCTAssertEqual(bill.nextDueDate, day(2024, 4, 10))
        XCTAssertEqual(try transactions.allRecords().count, 0, "Skipping records nothing")

        try bills.markPaid(billId: bill.id, payment: .newTransaction(amountMinorUnits: 5_000, date: day(2024, 4, 10), paymentMethodId: nil))
        try bills.delete(id: bill.id)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<RecurringBill>()), 0)
        XCTAssertEqual(try transactions.allRecords().count, 1, "Deleting a bill never deletes recorded payments")
    }

    func testBudgetSaveRulesAndDelete() throws {
        let groceries = try category("Groceries").id
        var d = BudgetDraft(currencyCode: "USD")
        d.categoryId = groceries; d.amountText = "400"
        let saved = try budgets.save(d, now: day(2024, 3, 17))
        XCTAssertEqual(saved.amountMinorUnits, 40_000)
        XCTAssertEqual(saved.effectiveStartMonth, day(2024, 3, 1, hour: 0))

        XCTAssertThrowsError(try budgets.save(d)) { XCTAssertEqual($0 as? BudgetDraft.ValidationError, .duplicate) }

        var edit = d
        edit.editingId = saved.id; edit.amountText = "450"
        XCTAssertEqual(try budgets.save(edit, now: day(2024, 6, 1)).effectiveStartMonth, saved.effectiveStartMonth)

        var income = BudgetDraft(currencyCode: "USD")
        income.categoryId = try category("Salary").id; income.amountText = "1"
        XCTAssertThrowsError(try budgets.save(income)) { XCTAssertEqual($0 as? BudgetDraft.ValidationError, .notExpenseCategory) }

        try budgets.delete(id: saved.id)
        XCTAssertEqual(try budgets.all().count, 0)
    }
}
