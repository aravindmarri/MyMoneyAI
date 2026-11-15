import SwiftUI

struct TransactionDetailView: View {
    let transaction: MoneyTransaction
    let category: SpendingCategory?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(CurrencyMath.format(transaction.amountMinorUnits, currencyCode: transaction.currencyCode))
                        .font(.largeTitle.weight(.semibold).monospacedDigit())
                    Text(transaction.transactionType.displayName + (transaction.isRefund ? " (refund)" : ""))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Details") {
                LabeledContent("Title", value: transaction.title)
                if let m = transaction.merchant { LabeledContent("Merchant", value: m) }
                LabeledContent("Date", value: transaction.transactionDate.formatted(date: .long, time: .omitted))
                LabeledContent("Category", value: category?.name ?? "Uncategorized")
                LabeledContent("Source", value: transaction.source == .receiptOCR ? "Receipt" : "Manual")
            }
            if let notes = transaction.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
            Section {
                LabeledContent("Recorded", value: transaction.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Last edited", value: transaction.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.footnote)
        }
        .navigationTitle(transaction.merchant ?? transaction.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
