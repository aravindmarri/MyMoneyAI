import Foundation

/// Value snapshot of an investment. All maths lives here so it is testable without SwiftData.
struct InvestmentHolding: Hashable, Sendable, Identifiable {
    var id: UUID
    var ticker: String
    var name: String
    var kind: InvestmentKind
    var shareMicros: Int64
    var purchasePriceMinorUnits: Int64
    var currentPriceMinorUnits: Int64
    var currencyCode: String
    var priceUpdatedAt: Date
}

/// Total invested, current value and gain/loss for one holding or a whole portfolio, in minor units.
struct InvestmentValuation: Equatable, Sendable {
    var investedMinorUnits: Int64
    var currentValueMinorUnits: Int64
    var gainMinorUnits: Int64 { currentValueMinorUnits - investedMinorUnits }
    /// Gain as a fraction of the amount invested; nil when nothing was invested.
    var gainFraction: Decimal? {
        investedMinorUnits == 0 ? nil : Decimal(gainMinorUnits) / Decimal(investedMinorUnits)
    }
    static let zero = InvestmentValuation(investedMinorUnits: 0, currentValueMinorUnits: 0)
}

enum InvestmentMath {
    static let microsPerShare: Int64 = 1_000_000
    static let maxShareFractionDigits = 6

    /// shares × price, exactly in Decimal, rounded half away from zero to minor units.
    static func value(shareMicros: Int64, priceMinorUnits: Int64) -> Int64 {
        let exact = Decimal(shareMicros) * Decimal(priceMinorUnits) / Decimal(microsPerShare)
        var e = exact, rounded = Decimal()
        NSDecimalRound(&rounded, &e, 0, .plain)
        let n = NSDecimalNumber(decimal: rounded)
        if n.compare(NSDecimalNumber(value: Int64.max)) == .orderedDescending { return .max }
        return n.int64Value
    }

    static func valuation(_ h: InvestmentHolding) -> InvestmentValuation {
        InvestmentValuation(investedMinorUnits: value(shareMicros: h.shareMicros, priceMinorUnits: h.purchasePriceMinorUnits),
                            currentValueMinorUnits: value(shareMicros: h.shareMicros, priceMinorUnits: h.currentPriceMinorUnits))
    }

    /// Sums holdings in `currencyCode`; holdings in other currencies are left out (no exchange rates offline).
    static func portfolio(_ holdings: [InvestmentHolding], currencyCode: String) -> InvestmentValuation {
        holdings.filter { $0.currencyCode == currencyCode }.reduce(.zero) { total, h in
            let v = valuation(h)
            return InvestmentValuation(investedMinorUnits: total.investedMinorUnits &+ v.investedMinorUnits,
                                       currentValueMinorUnits: total.currentValueMinorUnits &+ v.currentValueMinorUnits)
        }
    }

    /// Parses a share count such as "10", "2.5" or "0.123456". Returns nil for empty, negative,
    /// zero, non-numeric input or more than six decimal places.
    static func parseShares(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
              t.filter({ $0 == "." }).count <= 1 else { return nil }
        if let dot = t.firstIndex(of: "."), t.distance(from: t.index(after: dot), to: t.endIndex) > maxShareFractionDigits { return nil }
        guard let d = Decimal(string: t, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var scaled = d * Decimal(microsPerShare), rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let n = NSDecimalNumber(decimal: rounded)
        guard n.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else { return nil }
        let v = n.int64Value
        return v > 0 ? v : nil
    }

    /// "2.5" for 2_500_000 micros; no trailing zeros.
    static func formatShares(_ micros: Int64) -> String {
        let d = Decimal(micros) / Decimal(microsPerShare)
        return NSDecimalNumber(decimal: d).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Balances reported for one month.
struct SnapshotBalances: Equatable, Sendable {
    var month: Int
    var currencyCode: String
    var cashMinorUnits: Int64
    var bankMinorUnits: Int64
    var investmentsMinorUnits: Int64
    var creditCardDebtMinorUnits: Int64
    var recordedAt: Date
}

/// Tracked net worth = assets − liabilities.
///
/// Each asset is counted once, from its own balance: cash and bank from what the user reports,
/// investments from holdings (or the reported investment value). Transfers never enter this sum,
/// so moving ₹10,000 from the bank into investments lowers the bank balance and raises the
/// investment value: net worth is unchanged, never counted twice.
struct NetWorth: Equatable, Sendable {
    var cashMinorUnits: Int64
    var bankMinorUnits: Int64
    var investmentsMinorUnits: Int64
    var creditCardDebtMinorUnits: Int64

    var assetsMinorUnits: Int64 { cashMinorUnits &+ bankMinorUnits &+ investmentsMinorUnits }
    var liabilitiesMinorUnits: Int64 { creditCardDebtMinorUnits }
    var netWorthMinorUnits: Int64 { assetsMinorUnits &- liabilitiesMinorUnits }

    init(cashMinorUnits: Int64, bankMinorUnits: Int64, investmentsMinorUnits: Int64, creditCardDebtMinorUnits: Int64) {
        self.cashMinorUnits = cashMinorUnits; self.bankMinorUnits = bankMinorUnits
        self.investmentsMinorUnits = investmentsMinorUnits; self.creditCardDebtMinorUnits = creditCardDebtMinorUnits
    }

    init(_ s: SnapshotBalances) {
        self.init(cashMinorUnits: s.cashMinorUnits, bankMinorUnits: s.bankMinorUnits,
                  investmentsMinorUnits: s.investmentsMinorUnits, creditCardDebtMinorUnits: s.creditCardDebtMinorUnits)
    }

    /// Current tracked net worth: cash, bank and debt from the latest snapshot (the only place they
    /// are known), investments from today's holdings when there are any.
    static func current(latest: SnapshotBalances?, holdingsValueMinorUnits: Int64?) -> NetWorth {
        NetWorth(cashMinorUnits: latest?.cashMinorUnits ?? 0, bankMinorUnits: latest?.bankMinorUnits ?? 0,
                 investmentsMinorUnits: holdingsValueMinorUnits ?? latest?.investmentsMinorUnits ?? 0,
                 creditCardDebtMinorUnits: latest?.creditCardDebtMinorUnits ?? 0)
    }
}

enum SnapshotMonth {
    /// yyyymm for a date.
    static func key(for date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year ?? 0) * 100 + (c.month ?? 0)
    }

    /// The first day of a yyyymm month, for charts.
    static func date(for key: Int, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: key / 100, month: key % 100, day: 1))
    }

    /// The check-in is due from the 1st of a month until that month has a snapshot.
    static func isCheckInDue(today: Date, recordedMonths: Set<Int>, calendar: Calendar) -> Bool {
        !recordedMonths.contains(key(for: today, calendar: calendar))
    }
}
