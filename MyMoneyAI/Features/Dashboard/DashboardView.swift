import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \MoneyTransaction.transactionDate, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query(filter: #Predicate<RecurringBill> { $0.isActive }, sort: \RecurringBill.nextDueDate) private var bills: [RecurringBill]
    @Query private var settings: [AppSettings]
    @State private var model = DashboardViewModel()
    @State private var editorRoute: TransactionEditorRoute?

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    var body: some View {
        let summary = model.summary(records: transactions.map(\.record), currencyCode: currency, finance: app.finance)
        let monthTransactions = transactions.filter { model.range.contains($0.transactionDate) }
        let categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    monthSelector
                    summaryGrid(summary)
                    if summary.excludedOtherCurrencyCount > 0 {
                        Label("\(summary.excludedOtherCurrencyCount) transactions in other currencies are not included.",
                              systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    quickActions
                    recentSection(monthTransactions, categoryByID: categoryByID)
                    billsSection
                }
                .padding(.horizontal)
                .padding(.bottom, Theme.spacing)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Home")
            .sheet(item: $editorRoute) { TransactionEditorView(route: $0) }
        }
    }

    private var monthSelector: some View {
        HStack {
            Button { withAnimation { model.moveMonth(by: -1) } } label: {
                Image(systemName: "chevron.left").padding(8)
            }
            .accessibilityLabel("Previous month")
            Spacer()
            Text(model.monthTitle).font(.headline)
            Spacer()
            Button { withAnimation { model.moveMonth(by: 1) } } label: {
                Image(systemName: "chevron.right").padding(8)
            }
            .accessibilityLabel("Next month")
        }
        .card()
    }

    private func summaryGrid(_ s: PeriodSummary) -> some View {
        let ratio = s.expenseToIncomeRatio.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            SummaryCard(title: "Income", value: CurrencyMath.format(s.incomeMinorUnits, currencyCode: currency),
                        systemImage: "arrow.down.circle.fill", tint: Theme.income)
            SummaryCard(title: "Expenses", value: CurrencyMath.format(s.expenseMinorUnits, currencyCode: currency),
                        systemImage: "arrow.up.circle.fill", tint: Theme.expense)
            SummaryCard(title: "Net Cash Flow", value: CurrencyMath.format(s.netCashFlowMinorUnits, currencyCode: currency),
                        systemImage: "equal.circle.fill", tint: Theme.net)
            SummaryCard(title: "Spent of Income", value: ratio, systemImage: "percent", tint: .orange)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            Button { editorRoute = .new(currencyCode: currency) } label: {
                Label("Add", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
            }
            Button { app.selectedTab = .scan } label: {
                Label("Import Receipt", systemImage: "doc.viewfinder").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    @ViewBuilder
    private func recentSection(_ items: [MoneyTransaction], categoryByID: [UUID: SpendingCategory]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Transactions").font(.headline)
            if items.isEmpty {
                Text("No transactions recorded for \(model.monthTitle).")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(5)) { t in
                    TransactionRow(transaction: t, category: t.categoryId.flatMap { categoryByID[$0] })
                }
            }
        }
        .card()
    }

    private var billsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Upcoming Bills").font(.headline)
            if bills.isEmpty {
                Text("No recurring bills. Unpaid bills are tracked separately and never counted as spending.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(bills.prefix(3)) { bill in
                    HStack {
                        Text(bill.title)
                        Spacer()
                        Text(bill.nextDueDate, format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }
}
