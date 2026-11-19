import SwiftUI

struct TransactionRow: View {
    let transaction: MoneyTransaction
    var category: SpendingCategory?

    private var amountText: String {
        let formatted = CurrencyMath.format(transaction.amountMinorUnits, currencyCode: transaction.currencyCode)
        switch transaction.transactionType {
        case .income: return (transaction.isRefund ? "−" : "+") + formatted
        case .expense: return (transaction.isRefund ? "+" : "−") + formatted
        case .transfer, .adjustment: return formatted
        }
    }

    private var tint: Color {
        switch transaction.transactionType {
        case .income: Theme.income
        case .expense: .primary
        case .transfer, .adjustment: .secondary
        }
    }

    /// Category, plus the month it counts in when that differs from its date (e.g. "Salary · Counts in Nov").
    private var subtitle: String {
        let base = category?.name ?? transaction.transactionType.displayName
        let r = transaction.record
        guard r.isCountedInOtherMonth(calendar: .current) else { return base }
        return base + " · Counts in " + r.reportingDate(in: .current).formatted(.dateTime.month(.abbreviated))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category?.symbol ?? transaction.transactionType.symbol)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.color(category?.colorIdentifier ?? "gray"), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant ?? transaction.title).font(.body).lineLimit(1)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(amountText)
                .font(.body.monospacedDigit())
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}
