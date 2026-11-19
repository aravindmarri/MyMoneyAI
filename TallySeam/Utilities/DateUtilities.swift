import Foundation

/// Start-inclusive, end-exclusive date range. (Foundation's DateInterval.contains is end-inclusive,
/// which would double-count midnight on month boundaries, so it is deliberately not used.)
struct DateRange: Hashable, Sendable {
    let start: Date
    let end: Date
    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

extension Calendar {
    func monthRange(containing date: Date) -> DateRange {
        let start = dateInterval(of: .month, for: date)?.start ?? startOfDay(for: date)
        let end = self.date(byAdding: .month, value: 1, to: start) ?? start
        return DateRange(start: start, end: end)
    }

    func dayRange(containing date: Date) -> DateRange {
        let start = startOfDay(for: date)
        return DateRange(start: start, end: self.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    /// From January 1 of the current year through the end of today.
    func yearToDateRange(now: Date) -> DateRange {
        let start = dateInterval(of: .year, for: now)?.start ?? startOfDay(for: now)
        return DateRange(start: start, end: dayRange(containing: now).end)
    }

    /// Whole days from `from` through `through` (inclusive), normalized so start ≤ end.
    func range(fromDay from: Date, throughDay through: Date) -> DateRange {
        let a = startOfDay(for: min(from, through))
        return DateRange(start: a, end: dayRange(containing: max(from, through)).end)
    }

    func addingMonths(_ months: Int, to date: Date) -> Date {
        self.date(byAdding: .month, value: months, to: date) ?? date
    }
}
