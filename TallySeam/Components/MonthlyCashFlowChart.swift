import SwiftUI
import Charts

/// Side-by-side income and expense bars per month.
struct MonthlyCashFlowChart: View {
    let flows: [MonthlyFlow]
    let currencyCode: String
    @State private var selectedMonth: Date?

    private struct Bar: Identifiable {
        let month: Date
        let series: String
        let minorUnits: Int64
        var id: String { "\(month.timeIntervalSince1970)-\(series)" }
    }

    private var bars: [Bar] {
        flows.flatMap {
            [Bar(month: $0.monthStart, series: "Income", minorUnits: $0.incomeMinorUnits),
             Bar(month: $0.monthStart, series: "Expenses", minorUnits: $0.expenseMinorUnits)]
        }
    }

    private var selectedFlow: MonthlyFlow? {
        guard let selectedMonth else { return nil }
        let cal = Calendar.current
        return flows.first { cal.isDate($0.monthStart, equalTo: selectedMonth, toGranularity: .month) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let f = selectedFlow {
                Text("\(f.monthStart.formatted(.dateTime.month(.wide).year())): net \(CurrencyMath.format(f.netMinorUnits, currencyCode: currencyCode))")
                    .font(.subheadline.weight(.medium))
                    .transition(.opacity)
            }
            Chart(bars) { b in
                BarMark(x: .value("Month", b.month, unit: .month),
                        y: .value("Amount", CurrencyMath.plotValue(b.minorUnits, currencyCode: currencyCode)))
                    .position(by: .value("Series", b.series))
                    .foregroundStyle(by: .value("Series", b.series))
                    .cornerRadius(4)
                    .opacity(selectedMonth == nil || Calendar.current.isDate(b.month, equalTo: selectedMonth!, toGranularity: .month) ? 1 : 0.35)
                    .accessibilityLabel("\(b.month.formatted(.dateTime.month(.wide).year())) \(b.series)")
                    .accessibilityValue(CurrencyMath.format(b.minorUnits, currencyCode: currencyCode))
            }
            .chartForegroundStyleScale(["Income": Theme.income, "Expenses": Theme.expense])
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                }
            }
            .chartXSelection(value: $selectedMonth)
            .frame(height: 200)

            ChartDataTable(rows: flows.map {
                ($0.monthStart.formatted(.dateTime.month(.abbreviated).year()),
                 "+\(CurrencyMath.format($0.incomeMinorUnits, currencyCode: currencyCode))  −\(CurrencyMath.format($0.expenseMinorUnits, currencyCode: currencyCode))")
            })
        }
    }
}

/// Daily spending trend as a line over a soft area.
struct DailySpendingChart: View {
    let days: [DailyTotal]
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(days) { d in
                AreaMark(x: .value("Day", d.day, unit: .day),
                         y: .value("Spent", CurrencyMath.plotValue(d.minorUnits, currencyCode: currencyCode)))
                    .foregroundStyle(Theme.expense.opacity(0.15).gradient)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", d.day, unit: .day),
                         y: .value("Spent", CurrencyMath.plotValue(d.minorUnits, currencyCode: currencyCode)))
                    .foregroundStyle(Theme.expense)
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(d.day.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue(CurrencyMath.format(d.minorUnits, currencyCode: currencyCode))
            }
            .frame(height: 160)

            ChartDataTable(rows: days.filter { $0.minorUnits != 0 }.map {
                ($0.day.formatted(date: .abbreviated, time: .omitted), CurrencyMath.format($0.minorUnits, currencyCode: currencyCode))
            })
        }
    }
}
