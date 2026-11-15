import SwiftUI
import SwiftData

/// Phase 1: year-to-date summary from stored records. Charts arrive in Phase 3.
struct ReportsView: View {
    @Environment(AppContainer.self) private var app
    @Query private var transactions: [MoneyTransaction]
    @Query private var settings: [AppSettings]

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    private var yearToDate: DateRange {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .year, for: .now)?.start ?? cal.startOfDay(for: .now)
        return DateRange(start: start, end: cal.dayRange(containing: .now).end)
    }

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    EmptyStateView(title: "No Data to Report",
                                   systemImage: "chart.bar.xaxis",
                                   message: "Reports are calculated from your recorded transactions. Add income or expenses to see them here.")
                } else {
                    let s = app.finance.summary(of: transactions.map(\.record), in: yearToDate, currencyCode: currency)
                    List {
                        Section("Year to Date") {
                            LabeledContent("Income", value: CurrencyMath.format(s.incomeMinorUnits, currencyCode: currency))
                            LabeledContent("Expenses", value: CurrencyMath.format(s.expenseMinorUnits, currencyCode: currency))
                            LabeledContent("Net cash flow", value: CurrencyMath.format(s.netCashFlowMinorUnits, currencyCode: currency))
                            LabeledContent("Transactions", value: "\(s.transactionCount)")
                        }
                        Section {
                            Text("Net cash flow is income minus expenses for the period. It is not your bank balance or net worth.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Reports")
        }
    }
}
