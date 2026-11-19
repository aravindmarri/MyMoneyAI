import Foundation
import Testing
@testable import TallySeam

@Suite struct FinanceCalculationTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func tx(_ type: TransactionType, _ cents: Int64, _ d: Date, refund: Bool = false, currency: String = "USD") -> TransactionRecord {
        TransactionRecord(transactionDate: d, amountMinorUnits: cents, currencyCode: currency, title: "t",
                          transactionType: type, isRefund: refund)
    }

    var service: FinanceCalculationService { FinanceCalculationService(calendar: calendar) }

    @Test func incomeExpenseAndNet() {
        let r = [tx(.income, 500_000, date(2024, 3, 1)), tx(.expense, 12_345, date(2024, 3, 5)), tx(.expense, 655, date(2024, 3, 9))]
        let s = service.summary(of: r, in: calendar.monthRange(containing: date(2024, 3, 15)), currencyCode: "USD")
        #expect(s.incomeMinorUnits == 500_000)
        #expect(s.expenseMinorUnits == 13_000)
        #expect(s.netCashFlowMinorUnits == 487_000)
        #expect(s.expenseToIncomeRatio == Decimal(string: "0.026"))
    }

    @Test func transfersAndCreditCardRepaymentsAreNotExpenses() {
        let purchase = tx(.expense, 10_000, date(2024, 3, 2))
        let repayment = tx(.transfer, 10_000, date(2024, 3, 20))
        let adjustment = tx(.adjustment, 999, date(2024, 3, 21))
        let s = service.summary(of: [purchase, repayment, adjustment], in: calendar.monthRange(containing: date(2024, 3, 1)), currencyCode: "USD")
        #expect(s.expenseMinorUnits == 10_000)
        #expect(s.incomeMinorUnits == 0)
    }

    @Test func refundReducesExpenses() {
        let s = service.summary(of: [tx(.expense, 5_000, date(2024, 3, 2)), tx(.expense, 2_000, date(2024, 3, 3), refund: true)],
                                in: calendar.monthRange(containing: date(2024, 3, 1)), currencyCode: "USD")
        #expect(s.expenseMinorUnits == 3_000)
    }

    @Test func monthBoundaryIsStartInclusiveEndExclusive() {
        let firstInstantOfApril = calendar.monthRange(containing: date(2024, 4, 10)).start
        let lastMarch = firstInstantOfApril.addingTimeInterval(-1)
        let records = [tx(.expense, 100, firstInstantOfApril), tx(.expense, 200, lastMarch)]
        let march = service.summary(of: records, in: calendar.monthRange(containing: date(2024, 3, 10)), currencyCode: "USD")
        let april = service.summary(of: records, in: calendar.monthRange(containing: date(2024, 4, 10)), currencyCode: "USD")
        #expect(march.expenseMinorUnits == 200)
        #expect(april.expenseMinorUnits == 100)
    }

    @Test func leapYearFebruaryIncludesTheTwentyNinth() {
        let range = calendar.monthRange(containing: date(2024, 2, 1))
        #expect(range.contains(date(2024, 2, 29, 23)))
        #expect(!range.contains(date(2024, 3, 1, 0)))
    }

    @Test func otherCurrenciesAreExcludedNotConverted() {
        let s = service.summary(of: [tx(.expense, 1_000, date(2024, 3, 2)), tx(.expense, 9_000, date(2024, 3, 2), currency: "EUR")],
                                in: calendar.monthRange(containing: date(2024, 3, 1)), currencyCode: "USD")
        #expect(s.expenseMinorUnits == 1_000)
        #expect(s.excludedOtherCurrencyCount == 1)
    }

    @Test func cardPurchaseThisMonthRepaidNextMonthCountsOnlyWhenPurchased() {
        let purchase = tx(.expense, 30_000, date(2024, 1, 28))
        let repayment = tx(.transfer, 30_000, date(2024, 2, 15))
        let jan = service.summary(of: [purchase, repayment], in: calendar.monthRange(containing: date(2024, 1, 1)), currencyCode: "USD")
        let feb = service.summary(of: [purchase, repayment], in: calendar.monthRange(containing: date(2024, 2, 1)), currencyCode: "USD")
        #expect(jan.expenseMinorUnits == 30_000)
        #expect(feb.expenseMinorUnits == 0)
    }

    @Test func incomeReversalReducesIncome() {
        let s = service.summary(of: [tx(.income, 100_000, date(2024, 3, 1)), tx(.income, 10_000, date(2024, 3, 2), refund: true)],
                                in: calendar.monthRange(containing: date(2024, 3, 1)), currencyCode: "USD")
        #expect(s.incomeMinorUnits == 90_000)
    }

    @Test func usesTransactionDateNotCreatedAt() {
        var r = tx(.expense, 500, date(2024, 2, 20))
        r.createdAt = date(2024, 3, 5)   // entered late
        let feb = service.summary(of: [r], in: calendar.monthRange(containing: date(2024, 2, 1)), currencyCode: "USD")
        #expect(feb.expenseMinorUnits == 500)
    }

    @Test func monthBoundaryAcrossDSTAndTimeZones() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 2024-03-31 23:30 in New York is already April 1 in Tokyo.
        let instant = date(2024, 3, 31, 23).addingTimeInterval(30 * 60)
        #expect(calendar.monthRange(containing: date(2024, 3, 15)).contains(instant))
        #expect(tokyo.monthRange(containing: instant).start == tokyo.date(from: DateComponents(year: 2024, month: 4, day: 1))!)
    }

    @Test func noIncomeGivesNilRatio() {
        let s = service.summary(of: [tx(.expense, 1, date(2024, 3, 2))], in: calendar.monthRange(containing: date(2024, 3, 1)), currencyCode: "USD")
        #expect(s.expenseToIncomeRatio == nil)
    }
}

@Suite struct CurrencyMathTests {
    @Test func exponents() {
        #expect(CurrencyMath.exponent(for: "USD") == 2)
        #expect(CurrencyMath.exponent(for: "JPY") == 0)
        #expect(CurrencyMath.exponent(for: "KWD") == 3)
    }

    @Test func decimalRoundTrip() {
        #expect(CurrencyMath.minorUnits(from: Decimal(string: "19.99")!, currencyCode: "USD") == 1_999)
        #expect(CurrencyMath.minorUnits(from: Decimal(string: "0.105")!, currencyCode: "USD") == 11)
        #expect(CurrencyMath.minorUnits(from: Decimal(string: "1200")!, currencyCode: "JPY") == 1_200)
        #expect(CurrencyMath.decimal(fromMinorUnits: 1_999, currencyCode: "USD") == Decimal(string: "19.99"))
    }

    @Test func lastFourRejectsFullNumbers() {
        #expect(PaymentMethod.sanitizedLastFour("1234") == "1234")
        #expect(PaymentMethod.sanitizedLastFour("4111111111111111") == nil)
        #expect(PaymentMethod.sanitizedLastFour("12a4") == nil)
    }
}
