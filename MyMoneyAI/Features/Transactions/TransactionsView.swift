import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Query(sort: \MoneyTransaction.transactionDate, order: .reverse) private var transactions: [MoneyTransaction]
    @Query private var categories: [SpendingCategory]
    @State private var searchText = ""

    private var filtered: [MoneyTransaction] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return transactions }
        return transactions.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.merchant?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Groups by calendar day, newest first.
    private var sections: [(day: Date, items: [MoneyTransaction])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.transactionDate) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        let categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    EmptyStateView(title: "No Transactions",
                                   systemImage: "list.bullet.rectangle",
                                   message: "Income and expenses you record will appear here. Everything stays on this iPhone.")
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(sections, id: \.day) { section in
                            Section(section.day.formatted(date: .abbreviated, time: .omitted)) {
                                ForEach(section.items) { t in
                                    NavigationLink(value: t.id) {
                                        TransactionRow(transaction: t, category: t.categoryId.flatMap { categoryByID[$0] })
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Transactions")
            .searchable(text: $searchText, prompt: "Merchant or title")
            .navigationDestination(for: UUID.self) { id in
                if let t = transactions.first(where: { $0.id == id }) {
                    TransactionDetailView(transaction: t, category: t.categoryId.flatMap { categoryByID[$0] })
                }
            }
        }
    }
}
