import Foundation
import Testing
@testable import MyMoneyAI

@Suite struct TransactionDraftTests {
    let groceries = UUID()
    let salary = UUID()
    var kinds: [UUID: CategoryKind] { [groceries: .expense, salary: .income] }
    let now = Date(timeIntervalSince1970: 1_710_000_000)

    @Test func validExpenseProducesRecord() throws {
        var d = TransactionDraft(currencyCode: "USD", date: now)
        d.amountText = "1,234.56"
        d.merchant = "  Synthetic Grocer  "
        d.categoryId = groceries
        let r = try d.makeRecord(categoryKinds: kinds, now: now)
        #expect(r.amountMinorUnits == 123_456)
        #expect(r.title == "Synthetic Grocer")   // falls back to merchant
        #expect(r.merchant == "Synthetic Grocer")
        #expect(r.createdAt == now)
        #expect(r.source == .manual)
    }

    @Test(arguments: ["", "abc", "-5", "1.234"])
    func invalidOrAmbiguousAmounts(text: String) {
        var d = TransactionDraft(currencyCode: "USD")
        d.title = "x"
        d.amountText = text
        if text == "1.234" {
            // "1.234" is read as thousands grouping for USD, not $1.23
            #expect(d.amountMinorUnits == 123_400)
        } else {
            #expect(d.validationErrors(categoryKinds: [:]).contains(.invalidAmount))
        }
    }

    @Test func zeroAmountRejected() {
        var d = TransactionDraft(currencyCode: "USD")
        d.title = "x"; d.amountText = "0.00"
        #expect(throws: TransactionDraft.ValidationError.zeroAmount) { try d.makeRecord(categoryKinds: [:]) }
    }

    @Test func missingTitleRejected() {
        var d = TransactionDraft(currencyCode: "USD")
        d.amountText = "5"
        #expect(d.validationErrors(categoryKinds: [:]) == [.missingTitle])
    }

    @Test func categoryKindMustMatchType() {
        var d = TransactionDraft(currencyCode: "USD")
        d.title = "Pay"; d.amountText = "100"; d.type = .income; d.categoryId = groceries
        #expect(d.validationErrors(categoryKinds: kinds) == [.categoryKindMismatch])
    }

    @Test func transferClearsCategoryAndRefund() throws {
        var d = TransactionDraft(currencyCode: "USD")
        d.title = "Card payment"; d.amountText = "500"; d.type = .transfer
        d.categoryId = groceries; d.isRefund = true
        d.paymentMethodId = UUID(); d.transferDestinationPaymentMethodId = UUID()
        // categoryKindMismatch doesn't apply: transfers have no category kind
        let r = try d.makeRecord(categoryKinds: kinds)
        #expect(r.categoryId == nil)
        #expect(r.isRefund == false)
        #expect(r.transferDestinationPaymentMethodId != nil)
    }

    @Test func transferNeedsDistinctAccounts() {
        let acct = UUID()
        var d = TransactionDraft(currencyCode: "USD")
        d.title = "Move"; d.amountText = "10"; d.type = .transfer
        d.paymentMethodId = acct; d.transferDestinationPaymentMethodId = acct
        #expect(d.validationErrors(categoryKinds: [:]) == [.sameTransferAccounts])
    }

    @Test func nonTransferDropsDestination() throws {
        var d = TransactionDraft(currencyCode: "USD")
        d.title = "x"; d.amountText = "1"; d.transferDestinationPaymentMethodId = UUID()
        #expect(try d.makeRecord(categoryKinds: [:]).transferDestinationPaymentMethodId == nil)
    }

    @Test func editingPreservesIdentityAndCreationDate() throws {
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let original = TransactionRecord(transactionDate: created, createdAt: created, updatedAt: created, amountMinorUnits: 999,
                                         title: "Lunch", transactionType: .expense, categoryId: groceries, source: .receiptOCR)
        var d = TransactionDraft(editing: original)
        #expect(d.amountText == "9.99")
        d.amountText = "12.00"
        let r = try d.makeRecord(categoryKinds: kinds, now: now)
        #expect(r.id == original.id)
        #expect(r.createdAt == created)
        #expect(r.updatedAt == now)
        #expect(r.source == .receiptOCR)
        #expect(r.amountMinorUnits == 1_200)
    }

    @Test func duplicateIsNewAndDropsLinks() throws {
        let original = TransactionRecord(transactionDate: Date(timeIntervalSince1970: 1_600_000_000), amountMinorUnits: 4_500,
                                         title: "Gym", transactionType: .expense, receiptId: UUID(), recurringBillId: UUID(),
                                         source: .receiptOCR)
        let d = TransactionDraft.duplicating(original, date: now)
        let r = try d.makeRecord(categoryKinds: [:], now: now)
        #expect(r.id != original.id)
        #expect(r.transactionDate == now)
        #expect(r.receiptId == nil)
        #expect(r.recurringBillId == nil)
        #expect(r.source == .manual)
        #expect(r.amountMinorUnits == 4_500)
    }

    @Test func editableAmountRespectsExponent() {
        #expect(TransactionDraft.editableAmount(123_456, currencyCode: "USD") == "1234.56")
        #expect(TransactionDraft.editableAmount(1_200, currencyCode: "JPY") == "1200")
    }
}

@Suite struct CurrencyParsingTests {
    @Test(arguments: [
        ("12.50", 1_250), ("12,50", 1_250), ("12,5", 1_250), ("$1,234.56", 123_456), ("1.234,56", 123_456),
        ("1,234", 123_400), ("1 234.00", 123_400), ("0.01", 1), ("7", 700), ("7.", 700),
    ] as [(String, Int64)])
    func parsesUSD(text: String, expected: Int64) {
        #expect(CurrencyMath.parse(text, currencyCode: "USD") == expected)
    }

    @Test func rejectsTooManyFractionDigits() {
        #expect(CurrencyMath.parse("1.2345", currencyCode: "USD") == nil)
    }

    @Test func zeroExponentCurrency() {
        #expect(CurrencyMath.parse("1,200", currencyCode: "JPY") == 1_200)
        #expect(CurrencyMath.parse("12.5", currencyCode: "JPY") == nil)
    }
}

@Suite struct TransactionFilterTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()
    func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func filtersByTypeCategoryAndSearch() {
        let cat = UUID()
        let a = TransactionRecord(transactionDate: day(2024, 5, 1), amountMinorUnits: 100, merchant: "Corner Café", title: "Coffee",
                                  transactionType: .expense, categoryId: cat)
        let b = TransactionRecord(transactionDate: day(2024, 5, 1), amountMinorUnits: 100, title: "Salary", transactionType: .income)
        var f = TransactionFilter()
        f.types = [.expense]
        #expect(f.matches(a, calendar: calendar) && !f.matches(b, calendar: calendar))
        f = TransactionFilter(searchText: "café")
        #expect(f.matches(a, calendar: calendar) && !f.matches(b, calendar: calendar))
        f = TransactionFilter(categoryId: cat)
        #expect(f.matches(a, calendar: calendar) && !f.matches(b, calendar: calendar))
    }

    @Test func paymentMethodMatchesTransferDestination() {
        let card = UUID()
        let repayment = TransactionRecord(transactionDate: day(2024, 5, 3), amountMinorUnits: 100, title: "Card payment",
                                          transactionType: .transfer, paymentMethodId: UUID(), transferDestinationPaymentMethodId: card)
        #expect(TransactionFilter(paymentMethodId: card).matches(repayment, calendar: calendar))
    }

    @Test func endDateIncludesWholeDay() {
        let late = TransactionRecord(transactionDate: day(2024, 5, 10, 23), amountMinorUnits: 1, title: "x", transactionType: .expense)
        let nextDay = TransactionRecord(transactionDate: day(2024, 5, 11, 0), amountMinorUnits: 1, title: "x", transactionType: .expense)
        let f = TransactionFilter(startDate: day(2024, 5, 10, 15), endDate: day(2024, 5, 10, 8))
        #expect(f.matches(late, calendar: calendar))
        #expect(!f.matches(nextDay, calendar: calendar))
    }
}

@Suite struct CreditCardRepaymentDetectorTests {
    @Test(arguments: ["Credit Card Payment", "AUTOPAY - THANK YOU", "Payment Thank You", "Chase card payment"])
    func warnsOnRepaymentRecordedAsExpense(title: String) {
        #expect(CreditCardRepaymentDetector.shouldWarn(type: .expense, title: title, merchant: nil, categoryName: nil))
    }

    @Test func noWarningForOrdinaryPurchasesOrTransfers() {
        #expect(!CreditCardRepaymentDetector.shouldWarn(type: .expense, title: "Groceries", merchant: "Synthetic Mart", categoryName: "Groceries"))
        #expect(!CreditCardRepaymentDetector.shouldWarn(type: .transfer, title: "Credit card payment", merchant: nil, categoryName: nil))
    }

    @Test func recognizesRepaymentTransfer() {
        #expect(CreditCardRepaymentDetector.isRepaymentTransfer(type: .transfer, destinationType: .creditCard))
        #expect(!CreditCardRepaymentDetector.isRepaymentTransfer(type: .transfer, destinationType: .debitCard))
    }
}
