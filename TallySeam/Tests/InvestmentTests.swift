import Foundation
import SwiftData
import Testing
@testable import TallySeam

@Suite struct InvestmentMathTests {
    func holding(shares: Int64, buy: Int64, now: Int64, currency: String = "USD") -> InvestmentHolding {
        InvestmentHolding(id: UUID(), ticker: "VTI", name: "Total Market", kind: .etf, shareMicros: shares,
                          purchasePriceMinorUnits: buy, currentPriceMinorUnits: now, currencyCode: currency, priceUpdatedAt: .now)
    }

    @Test func investedValueAndGain() {
        // 10 shares bought at $200.00, now $250.50.
        let v = InvestmentMath.valuation(holding(shares: 10_000_000, buy: 20_000, now: 25_050))
        #expect(v.investedMinorUnits == 200_000)
        #expect(v.currentValueMinorUnits == 250_500)
        #expect(v.gainMinorUnits == 50_500)
        #expect(v.gainFraction == Decimal(string: "0.2525"))
    }

    @Test func lossIsNegative() {
        let v = InvestmentMath.valuation(holding(shares: 4_000_000, buy: 10_000, now: 7_500))
        #expect(v.gainMinorUnits == -10_000)
        #expect(v.gainFraction == Decimal(string: "-0.25"))
    }

    @Test func fractionalSharesAreExactAndRoundHalfUp() {
        // 0.333333 × $3.00 = $0.999999 → $1.00
        #expect(InvestmentMath.value(shareMicros: 333_333, priceMinorUnits: 300) == 100)
        // 2.5 × $0.01 = $0.025 → $0.03 (half away from zero, no float drift)
        #expect(InvestmentMath.value(shareMicros: 2_500_000, priceMinorUnits: 1) == 3)
        // 0.1 + 0.2 style values stay exact.
        #expect(InvestmentMath.value(shareMicros: 300_000, priceMinorUnits: 1_000) == 300)
    }

    @Test func zeroInvestedHasNoGainFraction() {
        #expect(InvestmentMath.valuation(holding(shares: 1_000_000, buy: 0, now: 500)).gainFraction == nil)
    }

    @Test func portfolioSumsOnlyItsCurrency() {
        let p = InvestmentMath.portfolio([holding(shares: 1_000_000, buy: 1_000, now: 1_500),
                                          holding(shares: 2_000_000, buy: 500, now: 400),
                                          holding(shares: 1_000_000, buy: 99_999, now: 99_999, currency: "EUR")], currencyCode: "USD")
        #expect(p.investedMinorUnits == 2_000)
        #expect(p.currentValueMinorUnits == 2_300)
        #expect(p.gainMinorUnits == 300)
    }

    @Test func parseShares() {
        #expect(InvestmentMath.parseShares("10") == 10_000_000)
        #expect(InvestmentMath.parseShares("2.5") == 2_500_000)
        #expect(InvestmentMath.parseShares("0,123456") == 123_456)
        #expect(InvestmentMath.parseShares("0.1234567") == nil)
        #expect(InvestmentMath.parseShares("0") == nil)
        #expect(InvestmentMath.parseShares("-1") == nil)
        #expect(InvestmentMath.parseShares("abc") == nil)
        #expect(InvestmentMath.parseShares("1.2.3") == nil)
        #expect(InvestmentMath.parseShares("") == nil)
        #expect(InvestmentMath.formatShares(2_500_000) == "2.5")
        #expect(InvestmentMath.formatShares(10_000_000) == "10")
    }
}

@Suite struct NetWorthTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    @Test func netWorthIsAssetsMinusLiabilities() {
        let n = NetWorth(cashMinorUnits: 10_000, bankMinorUnits: 500_000, investmentsMinorUnits: 250_000, creditCardDebtMinorUnits: 60_000)
        #expect(n.assetsMinorUnits == 760_000)
        #expect(n.liabilitiesMinorUnits == 60_000)
        #expect(n.netWorthMinorUnits == 700_000)
    }

    @Test func debtLargerThanAssetsGivesNegativeNetWorth() {
        #expect(NetWorth(cashMinorUnits: 0, bankMinorUnits: 1_000, investmentsMinorUnits: 0, creditCardDebtMinorUnits: 5_000).netWorthMinorUnits == -4_000)
    }

    @Test func moneyMovedFromBankToInvestmentsIsNotCountedTwice() {
        // Before: $5,000 in the bank. Transfer $1,000 into a brokerage and buy shares.
        let before = NetWorth(cashMinorUnits: 0, bankMinorUnits: 500_000, investmentsMinorUnits: 0, creditCardDebtMinorUnits: 0)
        let after = NetWorth(cashMinorUnits: 0, bankMinorUnits: 400_000, investmentsMinorUnits: 100_000, creditCardDebtMinorUnits: 0)
        #expect(before.netWorthMinorUnits == after.netWorthMinorUnits)
    }

    @Test func transferIntoInvestmentAccountIsNeverSpendingOrIncome() {
        let bank = UUID(), brokerage = UUID()
        let d = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let records = [
            TransactionRecord(transactionDate: d, amountMinorUnits: 300_000, title: "Salary", transactionType: .income, paymentMethodId: bank),
            TransactionRecord(transactionDate: d, amountMinorUnits: 100_000, title: "To brokerage", transactionType: .transfer,
                              paymentMethodId: bank, transferDestinationPaymentMethodId: brokerage),
        ]
        let s = FinanceCalculationService(calendar: calendar).summary(of: records, in: calendar.monthRange(containing: d), currencyCode: "USD")
        #expect(s.incomeMinorUnits == 300_000)
        #expect(s.expenseMinorUnits == 0)
        #expect(s.netCashFlowMinorUnits == 300_000)
    }

    @Test func currentNetWorthPrefersLiveHoldingsOverReportedValue() {
        let snap = SnapshotBalances(month: 202611, currencyCode: "USD", cashMinorUnits: 1_000, bankMinorUnits: 2_000,
                                    investmentsMinorUnits: 3_000, creditCardDebtMinorUnits: 500, recordedAt: .now)
        #expect(NetWorth.current(latest: snap, holdingsValueMinorUnits: 4_000).netWorthMinorUnits == 6_500)
        #expect(NetWorth.current(latest: snap, holdingsValueMinorUnits: nil).netWorthMinorUnits == 5_500)
        #expect(NetWorth.current(latest: nil, holdingsValueMinorUnits: nil).netWorthMinorUnits == 0)
    }

    @Test func monthKeysAndCheckInDue() {
        let nov1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!
        #expect(SnapshotMonth.key(for: nov1, calendar: calendar) == 202611)
        #expect(SnapshotMonth.date(for: 202611, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(SnapshotMonth.isCheckInDue(today: nov1, recordedMonths: [202610], calendar: calendar))
        #expect(!SnapshotMonth.isCheckInDue(today: nov1, recordedMonths: [202611], calendar: calendar))
    }
}

@MainActor
@Suite struct InvestmentRepositoryTests {
    @Test func addEditDeleteAndPriceDate() throws {
        let p = try PersistenceService(inMemory: true)
        let repo = InvestmentRepository(context: p.context)
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000), t2 = Date(timeIntervalSince1970: 3_000)
        let i = try repo.add(ticker: " vti ", name: "", kind: .etf, shareMicros: 1_000_000, purchasePriceMinorUnits: 100,
                             currentPriceMinorUnits: 120, currencyCode: "USD", now: t0)
        #expect(i.ticker == "VTI")
        #expect(i.name == "VTI")
        #expect(i.priceUpdatedAt == t0)

        // Changing shares only keeps the price date.
        try repo.update(i, ticker: "VTI", name: "Vanguard Total", kind: .etf, shareMicros: 2_000_000,
                        purchasePriceMinorUnits: 100, currentPriceMinorUnits: 120, now: t1)
        #expect(i.priceUpdatedAt == t0)
        try repo.updatePrice(i, currentPriceMinorUnits: 150, now: t2)
        #expect(i.priceUpdatedAt == t2)
        #expect(InvestmentMath.valuation(i.holding).currentValueMinorUnits == 300)

        #expect(throws: InvestmentError.missingTicker) {
            try repo.add(ticker: "  ", name: "x", kind: .stock, shareMicros: 1, purchasePriceMinorUnits: 1, currentPriceMinorUnits: 1, currencyCode: "USD")
        }
        #expect(throws: InvestmentError.invalidShares) {
            try repo.add(ticker: "A", name: "x", kind: .stock, shareMicros: 0, purchasePriceMinorUnits: 1, currentPriceMinorUnits: 1, currencyCode: "USD")
        }
        try repo.delete(i)
        #expect(try p.context.fetchCount(FetchDescriptor<Investment>()) == 0)
    }

    @Test func recordingAMonthAgainReplacesIt() throws {
        let p = try PersistenceService(inMemory: true)
        let repo = InvestmentRepository(context: p.context)
        try repo.recordSnapshot(month: 202611, currencyCode: "USD", cash: 1, bank: 2, investments: 3, creditCardDebt: 4)
        try repo.recordSnapshot(month: 202611, currencyCode: "USD", cash: 10, bank: 20, investments: 30, creditCardDebt: 40)
        try repo.recordSnapshot(month: 202612, currencyCode: "USD", cash: 5, bank: 5, investments: 5, creditCardDebt: 0)
        let all = try p.context.fetch(FetchDescriptor<MonthlySnapshot>())
        #expect(all.count == 2)
        #expect(all.first { $0.month == 202611 }?.cashMinorUnits == 10)
    }

    @Test func backupRoundTripKeepsInvestmentsAndSnapshots() throws {
        let source = try PersistenceService(inMemory: true)
        let repo = InvestmentRepository(context: source.context)
        try repo.add(ticker: "AAPL", name: "Apple", kind: .stock, shareMicros: 1_500_000, purchasePriceMinorUnits: 15_000,
                     currentPriceMinorUnits: 19_000, currencyCode: "USD")
        try repo.recordSnapshot(month: 202611, currencyCode: "USD", cash: 100, bank: 200, investments: 300, creditCardDebt: 50)
        let data = try BackupInvestmentData.make(from: source.context)
        try data.validate()

        let target = try PersistenceService(inMemory: true)
        try data.restore(into: target.context)
        try data.restore(into: target.context)   // second restore adds nothing
        #expect(try target.context.fetchCount(FetchDescriptor<Investment>()) == 1)
        #expect(try target.context.fetchCount(FetchDescriptor<MonthlySnapshot>()) == 1)
        #expect(try target.context.fetch(FetchDescriptor<Investment>()).first?.shareMicros == 1_500_000)
    }
}
