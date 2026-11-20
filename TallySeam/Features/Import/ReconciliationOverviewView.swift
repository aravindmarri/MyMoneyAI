import SwiftUI
import SwiftData

/// How well the month's records are backed by statements: verified vs unverified spending, spending
/// by account, bank cash flow from statements, and what is still open. Statement balances are shown
/// as printed on the statement, never as a live account balance.
struct ReconciliationOverviewView: View {
    @Environment(AppContainer.self) private var app
    @Query private var transactions: [MoneyTransaction]
    @Query(sort: \ImportedStatement.importedAt, order: .reverse) private var statements: [ImportedStatement]
    @Query private var lines: [StatementTransaction]
    @Query private var accounts: [FinancialAccount]
    @Query private var methods: [PaymentMethod]
    @Query private var settings: [AppSettings]
    @State private var month = Date()

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }
    private var calendar: Calendar { app.finance.calendar }
    private var range: DateRange { calendar.monthRange(containing: month) }

    var body: some View {
        let records = transactions.map(\.record)
        let verified = Set(lines.filter { $0.status == .matched || $0.status == .created }.compactMap(\.matchedTransactionId))
        let coverage = ReconciliationSummaryService.coverage(records: records, verifiedIds: verified, range: range,
                                                             currencyCode: currency, calendar: calendar)
        List {
            Section {
                HStack {
                    Button { month = calendar.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous month")
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                    Spacer()
                    Button { month = calendar.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next month")
                }
                .buttonStyle(.borderless)
            }
            coverageSection(coverage)
            accountSpendingSection(records)
            bankCashFlowSection
            statementsSection
        }
        .navigationTitle("Reconciliation")
    }

    private func coverageSection(_ c: SpendingCoverage) -> some View {
        Section {
            if c.totalMinorUnits == 0 {
                Text("No spending recorded this month.").foregroundStyle(.secondary)
            } else {
                ProgressView(value: Double(c.percentVerified), total: 100) {
                    Text("\(c.percentVerified)% of spending verified by a statement")
                }
                LabeledContent("Verified", value: "\(CurrencyMath.format(c.verifiedMinorUnits, currencyCode: currency)) · \(c.verifiedCount)")
                LabeledContent("Not yet verified", value: "\(CurrencyMath.format(c.unverifiedMinorUnits, currencyCode: currency)) · \(c.unverifiedCount)")
            }
        } header: {
            Text("Verified spending")
        } footer: {
            Text("An expense is verified when it's confirmed against, or added from, a statement line. Cash spending usually stays unverified, and that's fine. Totals are the same as on Home.")
        }
    }

    private func accountSpendingSection(_ records: [TransactionRecord]) -> some View {
        let totals = app.finance.expensesByPaymentMethod(records, in: range, currencyCode: currency)
        let names = Dictionary(methods.map { ($0.id, ($0.name, $0.type)) }, uniquingKeysWith: { a, _ in a })
        let cardTotal = totals.filter { $0.key.flatMap { names[$0]?.1 } == .creditCard }.reduce(Int64(0)) { $0 + $1.minorUnits }
        return Section {
            if totals.isEmpty { Text("No spending this month.").foregroundStyle(.secondary) }
            ForEach(totals) { g in
                LabeledContent(g.key.flatMap { names[$0]?.0 } ?? "No payment method",
                               value: CurrencyMath.format(g.minorUnits, currencyCode: currency))
            }
            if cardTotal > 0 { LabeledContent("All credit cards", value: CurrencyMath.format(cardTotal, currencyCode: currency)).bold() }
        } header: {
            Text("Spending by account")
        } footer: {
            Text("Card payments and transfers between your accounts aren't spending, so they never appear here.")
        }
    }

    private var bankCashFlowSection: some View {
        let bankAccounts = Set(accounts.filter { $0.accountType == .checking || $0.accountType == .savings }.map(\.id))
        let bankStatements = Dictionary(statements.filter { bankAccounts.contains($0.accountId) }.map { ($0.id, $0.accountId) },
                                        uniquingKeysWith: { a, _ in a })
        let monthLines = lines.filter { bankStatements[$0.statementId] != nil && !$0.isPending && $0.currencyCode == currency
            && range.contains($0.transactionDate) }
        let moneyIn = monthLines.filter { $0.direction == .moneyIn }.reduce(Int64(0)) { $0 + $1.amountMinorUnits }
        let moneyOut = monthLines.filter { $0.direction == .moneyOut }.reduce(Int64(0)) { $0 + $1.amountMinorUnits }
        return Section {
            if monthLines.isEmpty {
                Text("No bank statement covers this month.").foregroundStyle(.secondary)
            } else {
                LabeledContent("Money in", value: CurrencyMath.format(moneyIn, currencyCode: currency))
                LabeledContent("Money out", value: CurrencyMath.format(moneyOut, currencyCode: currency))
                LabeledContent("Net movement", value: CurrencyMath.format(moneyIn - moneyOut, currencyCode: currency))
            }
        } header: {
            Text("Bank cash flow (from statements)")
        } footer: {
            Text("Everything that moved through your bank accounts, including card payments and transfers. That's why it differs from income and spending, which leave those out.")
        }
    }

    private var statementsSection: some View {
        Section {
            if statements.isEmpty { Text("No statements imported yet.").foregroundStyle(.secondary) }
            ForEach(statements) { s in
                let sLines = lines.filter { $0.statementId == s.id }
                let open = sLines.filter { $0.status == .unmatched || $0.status == .suggested }.count
                let report = StatementBalanceValidator.validate(app.statements.balanceInput(s, lines: sLines))
                NavigationLink { StatementDetailView(statementId: s.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(accounts.first { $0.id == s.accountId }?.nickname ?? s.institutionName ?? s.originalFilename)
                        if let end = s.periodEnd { Text("Period ending \(end.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                        HStack(spacing: 8) {
                            Label(report.verdict.displayName, systemImage: symbol(report.verdict))
                                .foregroundStyle(color(report.verdict))
                            if open > 0 { Text("· \(open) to review").foregroundStyle(.orange) }
                        }
                        .font(.caption)
                        if let closing = s.closingBalance, let end = s.periodEnd {
                            Text("Statement balance \(CurrencyMath.format(closing, currencyCode: s.currencyCode)) on \(end.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Statements")
        } footer: {
            Text("A statement balance is what the bank printed on that date. TallySeam doesn't show it as your current balance, because later activity may not be imported.")
        }
    }

    private func symbol(_ v: BalanceVerdict) -> String {
        switch v {
        case .verified: "checkmark.seal.fill"
        case .differences: "exclamationmark.triangle.fill"
        case .notEnoughInformation: "questionmark.circle"
        }
    }

    private func color(_ v: BalanceVerdict) -> Color {
        switch v {
        case .verified: .green
        case .differences: .orange
        case .notEnoughInformation: .secondary
        }
    }
}

/// The balance checks for one statement.
struct StatementBalanceSection: View {
    let report: StatementBalanceReport
    let currencyCode: String

    var body: some View {
        Section {
            Label(report.verdict.displayName, systemImage: report.verdict == .verified ? "checkmark.seal.fill"
                  : (report.verdict == .differences ? "exclamationmark.triangle.fill" : "questionmark.circle"))
                .foregroundStyle(report.verdict == .verified ? Color.green : (report.verdict == .differences ? Color.orange : Color.secondary))
            Text(report.explanation).font(.footnote)
            ForEach(report.checks) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.title).font(.subheadline)
                        Spacer()
                        switch c.result {
                        case .balanced: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Adds up")
                        case .difference(let d): Text("Off by \(CurrencyMath.format(abs(d), currencyCode: currencyCode))").font(.caption).foregroundStyle(.orange)
                        case .notAvailable: Text("Can't check").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let e = c.expected, let a = c.actual, !c.result.isBalanced {
                        Text("Expected \(CurrencyMath.format(e, currencyCode: currencyCode)), statement shows \(CurrencyMath.format(a, currencyCode: currencyCode))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if case .notAvailable(let why) = c.result { Text(why).font(.caption).foregroundStyle(.secondary) }
                    if let hint = c.hint { Text(hint).font(.caption).foregroundStyle(.orange) }
                }
            }
            ForEach(Array(report.runningBalanceBreaks.enumerated()), id: \.offset) { _, b in
                Text("Page \(b.page), line \(b.line): balance should be \(CurrencyMath.format(b.expected, currencyCode: currencyCode)) but the statement shows \(CurrencyMath.format(b.printed, currencyCode: currencyCode)).")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Balance check")
        } footer: {
            Text("Bank: opening + deposits − withdrawals = closing. Card: previous balance + purchases + fees + interest − payments and credits = new balance.")
        }
    }
}
