import Foundation
import SwiftData

enum BudgetPeriod: String, Codable, Sendable { case monthly }

@Model
final class Budget {
    @Attribute(.unique) var id: UUID
    /// nil = overall monthly spending budget.
    var categoryId: UUID?
    var amountMinorUnits: Int64
    var currencyCode: String
    var periodRaw: String
    var effectiveStartMonth: Date
    var isActive: Bool

    init(id: UUID = UUID(), categoryId: UUID?, amountMinorUnits: Int64, currencyCode: String = CurrencyMath.defaultCode,
         effectiveStartMonth: Date, isActive: Bool = true) {
        self.id = id; self.categoryId = categoryId; self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode; self.periodRaw = BudgetPeriod.monthly.rawValue
        self.effectiveStartMonth = effectiveStartMonth; self.isActive = isActive
    }
}
