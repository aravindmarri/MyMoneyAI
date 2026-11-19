import Foundation
import SwiftData

enum RecurrenceRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case weekly, monthly, yearly, custom
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// A bill is an *obligation*, never an expense. Paying it creates or links exactly one
/// transaction and advances `nextDueDate`. Calculations never read bills, so they cannot double-count.
@Model
final class RecurringBill {
    @Attribute(.unique) var id: UUID
    var title: String
    var expectedAmountMinorUnits: Int64?
    var currencyCode: String
    var categoryId: UUID?
    var paymentMethodId: UUID?
    var recurrenceRaw: String
    /// Interval in days when the rule is `.custom`.
    var customIntervalDays: Int?
    var nextDueDate: Date
    var isActive: Bool
    var notes: String?

    init(id: UUID = UUID(), title: String, expectedAmountMinorUnits: Int64?, currencyCode: String = CurrencyMath.defaultCode,
         recurrenceRule: RecurrenceRule, nextDueDate: Date, isActive: Bool = true) {
        self.id = id; self.title = title; self.expectedAmountMinorUnits = expectedAmountMinorUnits
        self.currencyCode = currencyCode; self.recurrenceRaw = recurrenceRule.rawValue
        self.nextDueDate = nextDueDate; self.isActive = isActive
    }

    var recurrenceRule: RecurrenceRule {
        get { RecurrenceRule(rawValue: recurrenceRaw) ?? .monthly }
        set { recurrenceRaw = newValue.rawValue }
    }
}
