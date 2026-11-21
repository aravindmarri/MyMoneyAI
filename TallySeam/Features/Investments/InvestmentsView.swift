import SwiftUI
import SwiftData
import Charts

/// Stocks and ETFs entered by hand, the monthly check-in, and portfolio history. Fully offline:
/// every price is typed in by the user and shows the date it was last updated.
struct InvestmentsView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Investment.createdAt) private var investments: [Investment]
    @Query(sort: \MonthlySnapshot.month) private var snapshots: [MonthlySnapshot]
    @Query private var settings: [AppSettings]
    @State private var editorRoute: InvestmentEditorRoute?
    @State private var showCheckIn = false

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    var body: some View {
        let holdings = investments.map(\.holding)
        let portfolio = InvestmentMath.portfolio(holdings, currencyCode: currency)
        let otherCurrency = holdings.filter { $0.currencyCode != currency }.count
        let history = snapshots.filter { $0.currencyCode == currency }

        ScrollView {
            VStack(spacing: Theme.spacing) {
                summary(portfolio)
                if otherCurrency > 0 {
                    Label("\(otherCurrency) holdings in other currencies are not included in the total.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if SnapshotMonth.isCheckInDue(today: .now, recordedMonths: Set(history.map(\.month)), calendar: app.finance.calendar) {
                    CheckInPromptCard { showCheckIn = true }
                }
                holdingsSection(investments)
                PortfolioHistoryChart(snapshots: history, calendar: app.finance.calendar)
                Label("Prices are entered by you. TallySeam never connects to the internet, so update them whenever you like.",
                      systemImage: "wifi.slash")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)
            .padding(.bottom, Theme.spacing)
        }
        .brandScreen()
        .navigationTitle("Investments")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editorRoute = .new(currencyCode: currency) } label: { Label("Add Investment", systemImage: "plus") }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { showCheckIn = true } label: { Label("Monthly Check-In", systemImage: "calendar.badge.checkmark") }
            }
        }
        .sheet(item: $editorRoute) { InvestmentEditorView(route: $0) }
        .sheet(isPresented: $showCheckIn) { MonthlyCheckInView() }
    }

    private func summary(_ p: InvestmentValuation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Portfolio Value").font(.subheadline.weight(.medium)).opacity(0.85)
            Text(CurrencyMath.format(p.currentValueMinorUnits, currencyCode: currency))
                .font(.largeTitle.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.5).lineLimit(1)
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Invested").font(.caption).opacity(0.8)
                    Text(CurrencyMath.format(p.investedMinorUnits, currencyCode: currency)).font(.subheadline.monospacedDigit())
                }
                VStack(alignment: .leading) {
                    Text("Gain / Loss").font(.caption).opacity(0.8)
                    Text(GainText.text(p, currencyCode: currency)).font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
        }
        .hero()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func holdingsSection(_ items: [Investment]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Holdings").font(.headline)
                Spacer()
                Button { editorRoute = .new(currencyCode: currency) } label: { Label("Add Investment", systemImage: "plus.circle.fill") }
                    .font(.subheadline.weight(.semibold))
            }
            if items.isEmpty {
                Text("Add your stocks and ETFs to see their value and gain or loss.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(items) { i in
                    Button { editorRoute = .edit(i) } label: { InvestmentRow(investment: i) }
                        .buttonStyle(.plain)
                    if i.id != items.last?.id { Divider() }
                }
            }
        }
        .card()
    }
}

enum GainText {
    static func text(_ v: InvestmentValuation, currencyCode: String) -> String {
        let sign = v.gainMinorUnits > 0 ? "+" : (v.gainMinorUnits < 0 ? "−" : "")
        let amount = CurrencyMath.format(abs(v.gainMinorUnits), currencyCode: currencyCode)
        guard let f = v.gainFraction else { return sign + amount }
        let pct = (abs(f) as Decimal).formatted(.percent.precision(.fractionLength(1)))
        return "\(sign)\(amount) (\(sign)\(pct))"
    }

    static func color(_ v: InvestmentValuation) -> Color {
        v.gainMinorUnits > 0 ? Theme.income : (v.gainMinorUnits < 0 ? Theme.expense : .secondary)
    }
}

struct InvestmentRow: View {
    let investment: Investment

    var body: some View {
        let h = investment.holding
        let v = InvestmentMath.valuation(h)
        HStack(alignment: .top, spacing: 12) {
            Text(h.ticker.prefix(4))
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.name).font(.body.weight(.medium)).lineLimit(1)
                Text("\(h.ticker) · \(h.kind.displayName) · \(InvestmentMath.formatShares(h.shareMicros)) shares")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("Price \(CurrencyMath.format(h.currentPriceMinorUnits, currencyCode: h.currencyCode)) · updated \(h.priceUpdatedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(CurrencyMath.format(v.currentValueMinorUnits, currencyCode: h.currencyCode))
                    .font(.body.weight(.semibold).monospacedDigit())
                Text(GainText.text(v, currencyCode: h.currencyCode))
                    .font(.caption.monospacedDigit()).foregroundStyle(GainText.color(v))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit")
    }
}

struct CheckInPromptCard: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.checkmark").font(.title2).foregroundStyle(Theme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monthly check-in").font(.headline)
                    Text("Record this month's cash, bank, investments and card debt.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }
}

/// Monthly portfolio value and net worth from the check-ins.
struct PortfolioHistoryChart: View {
    let snapshots: [MonthlySnapshot]
    let calendar: Calendar

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let series: String
        let value: Double
    }

    var body: some View {
        let points: [Point] = snapshots.flatMap { s -> [Point] in
            guard let d = SnapshotMonth.date(for: s.month, calendar: calendar) else { return [] }
            return [Point(date: d, series: "Investments", value: CurrencyMath.plotValue(s.investmentsMinorUnits, currencyCode: s.currencyCode)),
                    Point(date: d, series: "Net Worth", value: CurrencyMath.plotValue(NetWorth(s.balances).netWorthMinorUnits, currencyCode: s.currencyCode))]
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Monthly Performance").font(.headline)
            if snapshots.count < 2 {
                Text(snapshots.isEmpty ? "Do your first monthly check-in to start the chart."
                                       : "Check in again next month to see the trend.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !points.isEmpty {
                Chart(points) { p in
                    LineMark(x: .value("Month", p.date, unit: .month), y: .value("Value", p.value))
                        .foregroundStyle(by: .value("Series", p.series))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Month", p.date, unit: .month), y: .value("Value", p.value))
                        .foregroundStyle(by: .value("Series", p.series))
                }
                .chartForegroundStyleScale(["Investments": Theme.brand, "Net Worth": Theme.income])
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .frame(height: 200)
                .accessibilityLabel("Monthly investments and net worth")
            }
        }
        .card()
    }
}

// MARK: - Editor

enum InvestmentEditorRoute: Identifiable {
    case new(currencyCode: String)
    case edit(Investment)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let i): i.id.uuidString
        }
    }
}

struct InvestmentEditorView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    private let editing: Investment?
    private let currencyCode: String
    @State private var ticker = ""
    @State private var name = ""
    @State private var kind: InvestmentKind = .stock
    @State private var sharesText = ""
    @State private var purchaseText = ""
    @State private var currentText = ""
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    init(route: InvestmentEditorRoute) {
        switch route {
        case .new(let code):
            editing = nil; currencyCode = code
        case .edit(let i):
            editing = i; currencyCode = i.currencyCode
            _ticker = State(initialValue: i.ticker)
            _name = State(initialValue: i.name)
            _kind = State(initialValue: i.kind)
            _sharesText = State(initialValue: InvestmentMath.formatShares(i.shareMicros))
            _purchaseText = State(initialValue: TransactionDraft.editableAmount(i.purchasePriceMinorUnits, currencyCode: i.currencyCode))
            _currentText = State(initialValue: TransactionDraft.editableAmount(i.currentPriceMinorUnits, currencyCode: i.currencyCode))
        }
    }

    private var shares: Int64? { InvestmentMath.parseShares(sharesText) }
    private var purchase: Int64? { CurrencyMath.parse(purchaseText, currencyCode: currencyCode) }
    private var current: Int64? { CurrencyMath.parse(currentText, currencyCode: currencyCode) }
    private var canSave: Bool { !InvestmentRepository.cleanTicker(ticker).isEmpty && shares != nil && purchase != nil && current != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Investment") {
                    TextField("Ticker symbol (e.g. VTI)", text: $ticker)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Name (optional)", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(InvestmentKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    TextField("Number of shares", text: $sharesText).keyboardType(.decimalPad)
                    LabeledContent("Purchase price") {
                        TextField(currencyCode, text: $purchaseText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Current price") {
                        TextField(currencyCode, text: $currentText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Shares and Prices (\(currencyCode), per share)")
                } footer: {
                    if let e = editing {
                        Text("Current price last updated \(e.priceUpdatedAt.formatted(date: .abbreviated, time: .shortened)). Changing it records today's date.")
                    } else {
                        Text("Prices are typed in by you; TallySeam never looks them up online.")
                    }
                }
                if let s = shares, let p = purchase, let c = current {
                    let v = InvestmentValuation(investedMinorUnits: InvestmentMath.value(shareMicros: s, priceMinorUnits: p),
                                                currentValueMinorUnits: InvestmentMath.value(shareMicros: s, priceMinorUnits: c))
                    Section("Calculated") {
                        LabeledContent("Total invested", value: CurrencyMath.format(v.investedMinorUnits, currencyCode: currencyCode))
                        LabeledContent("Current value", value: CurrencyMath.format(v.currentValueMinorUnits, currencyCode: currencyCode))
                        LabeledContent("Gain / loss") {
                            Text(GainText.text(v, currencyCode: currencyCode)).foregroundStyle(GainText.color(v))
                        }
                    }
                }
                if editing != nil {
                    Section {
                        Button("Delete Investment", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Deleting removes only this holding. Monthly check-ins already recorded are kept.")
                    }
                }
            }
            .brandScreen()
            .navigationTitle(editing == nil ? "Add Investment" : "Edit Investment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .confirmationDialog("Delete this investment?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Investment", role: .destructive, action: delete)
            }
            .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard let s = shares, let p = purchase, let c = current else { return }
        do {
            if let e = editing {
                try app.investments.update(e, ticker: ticker, name: name, kind: kind, shareMicros: s,
                                           purchasePriceMinorUnits: p, currentPriceMinorUnits: c)
            } else {
                try app.investments.add(ticker: ticker, name: name, kind: kind, shareMicros: s, purchasePriceMinorUnits: p,
                                        currentPriceMinorUnits: c, currencyCode: currencyCode)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func delete() {
        guard let e = editing else { return }
        do { try app.investments.delete(e); dismiss() } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - Monthly check-in

/// Records this month's balances. Fields start from last month's check-in; investments start from
/// today's holdings. Recording the same month again replaces it.
struct MonthlyCheckInView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MonthlySnapshot.month, order: .reverse) private var snapshots: [MonthlySnapshot]
    @Query private var investments: [Investment]
    @Query private var settings: [AppSettings]
    @State private var cashText = ""
    @State private var bankText = ""
    @State private var investmentsText = ""
    @State private var debtText = ""
    @State private var loaded = false
    @State private var errorMessage: String?

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }
    private var month: Int { SnapshotMonth.key(for: .now, calendar: app.finance.calendar) }

    private func amount(_ s: String) -> Int64? {
        s.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : CurrencyMath.parse(s, currencyCode: currency)
    }
    private var values: NetWorth? {
        guard let c = amount(cashText), let b = amount(bankText), let i = amount(investmentsText), let d = amount(debtText) else { return nil }
        return NetWorth(cashMinorUnits: c, bankMinorUnits: b, investmentsMinorUnits: i, creditCardDebtMinorUnits: d)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("Cash", systemImage: PaymentMethodType.cash.symbol, text: $cashText)
                    field("Bank and debit accounts", systemImage: PaymentMethodType.bankTransfer.symbol, text: $bankText)
                    field("Investments", systemImage: PaymentMethodType.investment.symbol, text: $investmentsText)
                } header: { Text("What You Have (\(currency))") } footer: {
                    Text("Moving money from the bank into investments lowers one and raises the other, so it's never counted twice.")
                }
                Section {
                    field("Credit card debt", systemImage: PaymentMethodType.creditCard.symbol, text: $debtText)
                } header: { Text("What You Owe") } footer: { Text("Enter the total you owe on all cards.") }
                if let v = values {
                    Section("Tracked Net Worth") {
                        LabeledContent("Assets", value: CurrencyMath.format(v.assetsMinorUnits, currencyCode: currency))
                        LabeledContent("Liabilities", value: CurrencyMath.format(v.liabilitiesMinorUnits, currencyCode: currency))
                        LabeledContent("Net worth", value: CurrencyMath.format(v.netWorthMinorUnits, currencyCode: currency))
                            .fontWeight(.semibold)
                    }
                }
            }
            .brandScreen()
            .navigationTitle("Check-In · \(monthTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(values == nil) }
            }
            .onAppear(perform: prefill)
            .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var monthTitle: String {
        (SnapshotMonth.date(for: month, calendar: app.finance.calendar) ?? .now).formatted(.dateTime.month(.abbreviated).year())
    }

    private func field(_ title: String, systemImage: String, text: Binding<String>) -> some View {
        LabeledContent {
            TextField("0", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        } label: { Label(title, systemImage: systemImage) }
    }

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        let mine = snapshots.filter { $0.currencyCode == currency }
        let base = mine.first { $0.month == month } ?? mine.first
        func text(_ v: Int64) -> String { TransactionDraft.editableAmount(v, currencyCode: currency) }
        if let b = base {
            cashText = text(b.cashMinorUnits); bankText = text(b.bankMinorUnits); debtText = text(b.creditCardDebtMinorUnits)
            investmentsText = text(b.investmentsMinorUnits)
        }
        let holdings = investments.map(\.holding).filter { $0.currencyCode == currency }
        if !holdings.isEmpty, base?.month != month {
            investmentsText = text(InvestmentMath.portfolio(holdings, currencyCode: currency).currentValueMinorUnits)
        }
    }

    private func save() {
        guard let v = values else { return }
        do {
            try app.investments.recordSnapshot(month: month, currencyCode: currency, cash: v.cashMinorUnits, bank: v.bankMinorUnits,
                                               investments: v.investmentsMinorUnits, creditCardDebt: v.creditCardDebtMinorUnits)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - Dashboard card

/// Net worth on Home: cash and bank, investments, card debt and the total. Opens Investments.
struct NetWorthCard: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \MonthlySnapshot.month, order: .reverse) private var snapshots: [MonthlySnapshot]
    @Query private var investments: [Investment]
    let currencyCode: String
    let onCheckIn: () -> Void

    var body: some View {
        let latest = snapshots.first { $0.currencyCode == currencyCode }
        let holdings = investments.map(\.holding).filter { $0.currencyCode == currencyCode }
        let live = holdings.isEmpty ? nil : InvestmentMath.portfolio(holdings, currencyCode: currencyCode).currentValueMinorUnits
        let n = NetWorth.current(latest: latest?.balances, holdingsValueMinorUnits: live)
        let due = SnapshotMonth.isCheckInDue(today: .now, recordedMonths: Set(snapshots.filter { $0.currencyCode == currencyCode }.map(\.month)),
                                             calendar: app.finance.calendar)

        VStack(alignment: .leading, spacing: 12) {
            NavigationLink { InvestmentsView() } label: {
                HStack {
                    Label("Tracked Net Worth", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            Text(CurrencyMath.format(n.netWorthMinorUnits, currencyCode: currencyCode))
                .font(.title.weight(.bold).monospacedDigit())
                .foregroundStyle(n.netWorthMinorUnits < 0 ? Theme.expense : .primary)
                .minimumScaleFactor(0.6).lineLimit(1)
            VStack(spacing: 6) {
                row("Cash and bank", n.cashMinorUnits &+ n.bankMinorUnits, color: .primary)
                row("Investments", n.investmentsMinorUnits, color: Theme.brand)
                row("Credit card debt", -n.creditCardDebtMinorUnits, color: Theme.expense)
            }
            .font(.subheadline)
            if let l = latest {
                Text("Cash, bank and debt as of your \(l.recordedAt.formatted(date: .abbreviated, time: .omitted)) check-in\(live == nil ? "" : "; investments at your latest prices").")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Do a monthly check-in to add your cash, bank and card balances.").font(.caption).foregroundStyle(.secondary)
            }
            if due {
                Button(action: onCheckIn) { Label("Monthly check-in", systemImage: "calendar.badge.checkmark") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .card()
    }

    private func row(_ title: String, _ minor: Int64, color: Color) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(CurrencyMath.format(minor, currencyCode: currencyCode)).monospacedDigit().foregroundStyle(color)
        }
    }
}
