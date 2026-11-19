import Foundation
import Testing
@testable import TallySeam

@Suite struct ReportCalculationTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    var finance: FinanceCalculationService { FinanceCalculationService(calendar: calendar) }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    func march() -> DateRange { calendar.monthRange(containing: date(2024, 3, 1)) }

    func expense(_ cents: Int64, _ d: Date, category: UUID? = nil, method: UUID? = nil, merchant: String? = nil,
                 refund: Bool = false, currency: String = "USD") -> TransactionRecord {
        TransactionRecord(transactionDate: d, amountMinorUnits: cents, currencyCode: currency, merchant: merchant, title: "t",
                          transactionType: .expense, categoryId: category, paymentMethodId: method, isRefund: refund)
    }

    @Test func categoryTotalsNetOfRefundsSortedDescending() {
        let food = UUID(), fun = UUID()
        let r = [expense(3_000, date(2024, 3, 2), category: food), expense(1_000, date(2024, 3, 3), category: food, refund: true),
                 expense(5_000, date(2024, 3, 4), category: fun), expense(700, date(2024, 3, 5))]
        let totals = finance.expensesByCategory(r, in: march(), currencyCode: "USD")
        #expect(totals.map(\.key) == [fun, food, nil])
        #expect(totals.map(\.minorUnits) == [5_000, 2_000, 700])
    }

    @Test func categoryFullyRefundedIsOmitted() {
        let c = UUID()
        let r = [expense(1_000, date(2024, 3, 2), category: c), expense(1_000, date(2024, 3, 9), category: c, refund: true)]
        #expect(finance.expensesByCategory(r, in: march(), currencyCode: "USD").isEmpty)
    }

    @Test func categoryTotalsSumToSummaryExpenses() {
        let a = UUID(), b = UUID()
        let r = [expense(1_234, date(2024, 3, 1), category: a), expense(4_321, date(2024, 3, 31, 23), category: b),
                 expense(99, date(2024, 3, 15)),
                 TransactionRecord(transactionDate: date(2024, 3, 10), amountMinorUnits: 9_999, title: "card", transactionType: .transfer)]
        let sum = finance.expensesByCategory(r, in: march(), currencyCode: "USD").reduce(0) { $0 + $1.minorUnits }
        #expect(sum == finance.summary(of: r, in: march(), currencyCode: "USD").expenseMinorUnits)
    }

    @Test func breakdownsIgnoreTransfersIncomeAndOtherCurrencies() {
        let card = UUID()
        let r = [expense(2_000, date(2024, 3, 2), method: card),
                 expense(9_000, date(2024, 3, 2), method: card, currency: "EUR"),
                 TransactionRecord(transactionDate: date(2024, 3, 20), amountMinorUnits: 2_000, title: "Card payment",
                                   transactionType: .transfer, transferDestinationPaymentMethodId: card),
                 TransactionRecord(transactionDate: date(2024, 3, 1), amountMinorUnits: 500_000, title: "Pay",
                                   transactionType: .income, paymentMethodId: card)]
        let byMethod = finance.expensesByPaymentMethod(r, in: march(), currencyCode: "USD")
        #expect(byMethod == [GroupTotal(key: card, minorUnits: 2_000)])
    }

    @Test func topMerchantsMergeCaseAndWhitespace() {
        let r = [expense(1_000, date(2024, 3, 1), merchant: "Corner Café"), expense(500, date(2024, 3, 2), merchant: "  corner café "),
                 expense(2_000, date(2024, 3, 3), merchant: "Book Nook"), expense(100, date(2024, 3, 4), merchant: "Tiny Shop")]
        let top = finance.topMerchants(r, in: march(), currencyCode: "USD", limit: 2)
        #expect(top.map(\.minorUnits) == [2_000, 1_500])
        #expect(top[1].count == 2)
        #expect(top[1].name == "Corner Café")
    }

    @Test func dailyIncludesEveryDayIncludingZeros() {
        let r = [expense(300, date(2024, 2, 29, 9)), expense(200, date(2024, 2, 29, 21))]
        let feb = calendar.monthRange(containing: date(2024, 2, 1))
        let days = finance.dailyExpenses(r, in: feb, currencyCode: "USD")
        #expect(days.count == 29)                   // leap year
        #expect(days.last?.minorUnits == 500)
        #expect(days.dropLast().allSatisfy { $0.minorUnits == 0 })
    }

    @Test func dailyHandlesDSTMonth() {
        // March 2024 in Los Angeles has a 23-hour day (DST starts March 10).
        let days = finance.dailyExpenses([], in: march(), currencyCode: "USD")
        #expect(days.count == 31)
        #expect(Set(days.map(\.day)).count == 31)
    }

    @Test func monthlyFlowsOldestFirstWithEmptyMonths() {
        let r = [TransactionRecord(transactionDate: date(2024, 1, 15), amountMinorUnits: 100_000, title: "Pay", transactionType: .income),
                 expense(40_000, date(2024, 3, 5))]
        let flows = finance.monthlyFlows(r, endingWith: date(2024, 3, 20), count: 3, currencyCode: "USD")
        #expect(flows.map(\.monthStart) == [1, 2, 3].map { calendar.monthRange(containing: date(2024, $0, 1)).start })
        #expect(flows.map(\.incomeMinorUnits) == [100_000, 0, 0])
        #expect(flows.map(\.expenseMinorUnits) == [0, 0, 40_000])
        #expect(flows[0].netMinorUnits == 100_000)
    }

    @Test func monthlyFlowsCrossYearBoundary() {
        let flows = finance.monthlyFlows([], endingWith: date(2024, 1, 10), count: 3, currencyCode: "USD")
        #expect(flows.map { calendar.component(.month, from: $0.monthStart) } == [11, 12, 1])
    }

    @Test func monthlyFlowsForRangeAreClippedToRange() {
        let r = [expense(1_000, date(2024, 1, 5)), expense(2_000, date(2024, 1, 25)), expense(4_000, date(2024, 2, 10))]
        let range = calendar.range(fromDay: date(2024, 1, 20), throughDay: date(2024, 2, 29))
        let flows = finance.monthlyFlows(r, in: range, currencyCode: "USD")
        #expect(flows.map(\.expenseMinorUnits) == [2_000, 4_000])
        #expect(flows.reduce(0) { $0 + $1.expenseMinorUnits } == finance.summary(of: r, in: range, currencyCode: "USD").expenseMinorUnits)
    }

    @Test func monthOverMonthChange() {
        let r = [expense(10_000, date(2024, 2, 10)), expense(12_500, date(2024, 3, 10))]
        let c = finance.monthOverMonth(r, month: date(2024, 3, 15), currencyCode: "USD")
        #expect(c.previous.expenseMinorUnits == 10_000)
        #expect(c.current.expenseMinorUnits == 12_500)
        #expect(c.expenseChange == Decimal(string: "0.25"))
        #expect(c.incomeChange == nil)
    }

    @Test func yearToDateRangeStartsJanFirstAndIncludesToday() {
        let now = date(2024, 6, 15, 18)
        let ytd = calendar.yearToDateRange(now: now)
        #expect(ytd.start == calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
        #expect(ytd.contains(date(2024, 6, 15, 23)))
        #expect(!ytd.contains(date(2024, 6, 16, 0)))
    }

    @Test func customRangeNormalizesReversedDates() {
        let r = calendar.range(fromDay: date(2024, 3, 10), throughDay: date(2024, 3, 1))
        #expect(r.contains(date(2024, 3, 1, 0)))
        #expect(r.contains(date(2024, 3, 10, 23)))
        #expect(!r.contains(date(2024, 3, 11, 0)))
    }

    @Test func reportPeriodPresets() {
        let now = date(2024, 3, 15)
        let start = Date.distantPast, end = Date.distantPast
        #expect(ReportPeriod.lastMonth.range(now: now, customStart: start, customEnd: end, calendar: calendar)
                == calendar.monthRange(containing: date(2024, 2, 1)))
        let three = ReportPeriod.last3Months.range(now: now, customStart: start, customEnd: end, calendar: calendar)
        #expect(three.start == calendar.monthRange(containing: date(2024, 1, 1)).start)
        #expect(three.end == calendar.monthRange(containing: now).end)
    }
}
