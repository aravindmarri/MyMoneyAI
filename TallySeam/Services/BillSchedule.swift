import Foundation

/// Due status of a bill relative to today, compared by calendar day.
enum BillDueStatus: Equatable, Sendable {
    case inactive
    case overdue(days: Int)
    case dueToday
    case dueSoon(days: Int)
    case upcoming(days: Int)

    var label: String {
        switch self {
        case .inactive: "Paused"
        case .overdue(let d): d == 1 ? "1 day overdue" : "\(d) days overdue"
        case .dueToday: "Due today"
        case .dueSoon(let d), .upcoming(let d): d == 1 ? "Due tomorrow" : "Due in \(d) days"
        }
    }

    var symbol: String {
        switch self {
        case .inactive: "pause.circle"
        case .overdue: "exclamationmark.circle.fill"
        case .dueToday: "clock.badge.exclamationmark.fill"
        case .dueSoon: "clock.fill"
        case .upcoming: "calendar"
        }
    }

    /// Overdue and due today/soon need attention.
    var needsAttention: Bool {
        switch self {
        case .overdue, .dueToday, .dueSoon: true
        case .inactive, .upcoming: false
        }
    }
}

/// Pure scheduling rules for recurring bills. Bills are obligations; nothing here touches totals.
enum BillSchedule {
    /// A bill due within this many days (but not today) is "due soon".
    static let dueSoonDays = 7
    static let maxCustomIntervalDays = 3_660

    static func status(dueDate: Date, isActive: Bool, now: Date, calendar: Calendar) -> BillDueStatus {
        guard isActive else { return .inactive }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: dueDate)).day ?? 0
        if days < 0 { return .overdue(days: -days) }
        if days == 0 { return .dueToday }
        if days <= dueSoonDays { return .dueSoon(days: days) }
        return .upcoming(days: days)
    }

    /// The due date one period after `dueDate`.
    /// Monthly and yearly bills due on the last day of a month stay on the last day
    /// (Jan 31 → Feb 29 → Mar 31), so they don't drift to the 28th or 29th.
    /// Returns nil for a custom rule without a valid interval.
    static func nextDueDate(after dueDate: Date, rule: RecurrenceRule, customIntervalDays: Int?, calendar: Calendar) -> Date? {
        switch rule {
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: dueDate)
        case .custom:
            guard let n = customIntervalDays, (1...maxCustomIntervalDays).contains(n) else { return nil }
            return calendar.date(byAdding: .day, value: n, to: dueDate)
        case .monthly, .yearly:
            let component: Calendar.Component = rule == .monthly ? .month : .year
            guard let next = calendar.date(byAdding: component, value: 1, to: dueDate) else { return nil }
            guard isLastDayOfMonth(dueDate, calendar: calendar) else { return next }
            return lastDayOfMonth(containing: next, matchingTimeOf: dueDate, calendar: calendar) ?? next
        }
    }

    static func isLastDayOfMonth(_ date: Date, calendar: Calendar) -> Bool {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return false }
        return calendar.component(.month, from: tomorrow) != calendar.component(.month, from: date)
    }

    private static func lastDayOfMonth(containing date: Date, matchingTimeOf time: Date, calendar: Calendar) -> Date? {
        guard let days = calendar.range(of: .day, in: .month, for: date)?.count else { return nil }
        var c = calendar.dateComponents([.year, .month], from: date)
        let t = calendar.dateComponents([.hour, .minute, .second], from: time)
        c.day = days; c.hour = t.hour; c.minute = t.minute; c.second = t.second
        return calendar.date(from: c)
    }
}

/// Editable form state for a recurring bill.
struct BillDraft: Equatable, Sendable {
    enum ValidationError: Error, Equatable, Sendable, LocalizedError {
        case missingTitle, invalidAmount, invalidInterval

        var errorDescription: String? {
            switch self {
            case .missingTitle: "Enter a name for the bill."
            case .invalidAmount: "Enter a valid amount greater than zero, or leave it empty if it varies."
            case .invalidInterval: "Enter how many days between payments (1 to \(BillSchedule.maxCustomIntervalDays))."
            }
        }
    }

    var editingId: UUID?
    var title = ""
    /// Empty means the amount varies and is entered when paying.
    var amountText = ""
    var currencyCode: String
    var categoryId: UUID?
    var paymentMethodId: UUID?
    var rule: RecurrenceRule = .monthly
    var customIntervalText = ""
    var nextDueDate: Date
    var notes = ""
    var isActive = true

    init(currencyCode: String, nextDueDate: Date) {
        self.currencyCode = currencyCode
        self.nextDueDate = nextDueDate
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var customIntervalDays: Int? { Int(customIntervalText.trimmingCharacters(in: .whitespaces)) }

    /// nil when empty; `.some(nil)` when the text is not a valid positive amount.
    var expectedAmount: Int64?? {
        let t = amountText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        guard let v = CurrencyMath.parse(t, currencyCode: currencyCode), v > 0 else { return nil }
        return .some(v)
    }

    var validationErrors: [ValidationError] {
        var e: [ValidationError] = []
        if trimmedTitle.isEmpty { e.append(.missingTitle) }
        if expectedAmount == nil { e.append(.invalidAmount) }
        if rule == .custom, !(1...BillSchedule.maxCustomIntervalDays).contains(customIntervalDays ?? 0) { e.append(.invalidInterval) }
        return e
    }
}

/// Editable form state for a monthly budget.
struct BudgetDraft: Equatable, Sendable {
    enum ValidationError: Error, Equatable, Sendable, LocalizedError {
        case invalidAmount, duplicate, notExpenseCategory

        var errorDescription: String? {
            switch self {
            case .invalidAmount: "Enter a monthly limit greater than zero."
            case .duplicate: "There is already an active budget for this category and currency."
            case .notExpenseCategory: "Budgets can only use expense categories."
            }
        }
    }

    var editingId: UUID?
    /// nil = overall spending budget.
    var categoryId: UUID?
    var amountText = ""
    var currencyCode: String
    var isActive = true

    init(currencyCode: String) { self.currencyCode = currencyCode }

    var amountMinorUnits: Int64? {
        guard let v = CurrencyMath.parse(amountText, currencyCode: currencyCode), v > 0 else { return nil }
        return v
    }
}
