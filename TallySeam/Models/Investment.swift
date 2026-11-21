import Foundation
import SwiftData

enum InvestmentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case stock, etf
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .stock: "Stock"
        case .etf: "ETF"
        }
    }
}

/// A stock or ETF holding entered by hand. Prices are typed in by the user; the app never fetches them.
///
/// Shares are stored as millionths of a share (`shareMicros`), so fractional shares are exact.
/// Prices are per share, in minor units of `currencyCode`. Values are calculated with Decimal.
@Model
final class Investment {
    @Attribute(.unique) var id: UUID
    var ticker: String
    var name: String
    var kindRaw: String
    var shareMicros: Int64
    var purchasePriceMinorUnits: Int64
    var currentPriceMinorUnits: Int64
    var currencyCode: String
    /// When `currentPriceMinorUnits` was last typed in.
    var priceUpdatedAt: Date
    var createdAt: Date
    var notes: String?

    init(id: UUID = UUID(), ticker: String, name: String, kind: InvestmentKind, shareMicros: Int64,
         purchasePriceMinorUnits: Int64, currentPriceMinorUnits: Int64, currencyCode: String,
         priceUpdatedAt: Date = .now, createdAt: Date = .now, notes: String? = nil) {
        self.id = id; self.ticker = ticker; self.name = name; self.kindRaw = kind.rawValue
        self.shareMicros = shareMicros; self.purchasePriceMinorUnits = purchasePriceMinorUnits
        self.currentPriceMinorUnits = currentPriceMinorUnits; self.currencyCode = currencyCode
        self.priceUpdatedAt = priceUpdatedAt; self.createdAt = createdAt; self.notes = notes
    }

    var kind: InvestmentKind { InvestmentKind(rawValue: kindRaw) ?? .stock }

    var holding: InvestmentHolding {
        InvestmentHolding(id: id, ticker: ticker, name: name, kind: kind, shareMicros: shareMicros,
                          purchasePriceMinorUnits: purchasePriceMinorUnits, currentPriceMinorUnits: currentPriceMinorUnits,
                          currencyCode: currencyCode, priceUpdatedAt: priceUpdatedAt)
    }
}

/// Balances the user reports for one month (usually on the 1st): cash, bank, investments and
/// credit-card debt. All amounts are non-negative minor units; debt is the amount owed.
/// One snapshot per month and currency; recording again replaces it.
@Model
final class MonthlySnapshot {
    @Attribute(.unique) var id: UUID
    /// yyyymm, e.g. 202611.
    var month: Int
    var currencyCode: String
    var cashMinorUnits: Int64
    var bankMinorUnits: Int64
    var investmentsMinorUnits: Int64
    var creditCardDebtMinorUnits: Int64
    var recordedAt: Date
    var notes: String?

    init(id: UUID = UUID(), month: Int, currencyCode: String, cashMinorUnits: Int64, bankMinorUnits: Int64,
         investmentsMinorUnits: Int64, creditCardDebtMinorUnits: Int64, recordedAt: Date = .now, notes: String? = nil) {
        self.id = id; self.month = month; self.currencyCode = currencyCode
        self.cashMinorUnits = cashMinorUnits; self.bankMinorUnits = bankMinorUnits
        self.investmentsMinorUnits = investmentsMinorUnits; self.creditCardDebtMinorUnits = creditCardDebtMinorUnits
        self.recordedAt = recordedAt; self.notes = notes
    }

    var balances: SnapshotBalances {
        SnapshotBalances(month: month, currencyCode: currencyCode, cashMinorUnits: cashMinorUnits, bankMinorUnits: bankMinorUnits,
                         investmentsMinorUnits: investmentsMinorUnits, creditCardDebtMinorUnits: creditCardDebtMinorUnits,
                         recordedAt: recordedAt)
    }
}
