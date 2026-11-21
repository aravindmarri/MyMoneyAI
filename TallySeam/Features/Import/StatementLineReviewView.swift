import SwiftUI
import SwiftData

/// Review one statement line: compare it with the suggested transaction side by side, then confirm,
/// reject, pick another, add it as new, mark it as a transfer, skip it, or leave it for later.
struct StatementLineReviewView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let lineId: UUID

    @Query private var lines: [StatementTransaction]
    @Query private var matches: [ReconciliationMatch]
    @Query private var transactions: [MoneyTransaction]
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query(sort: \PaymentMethod.name) private var methods: [PaymentMethod]
    @State private var useStatementAmount = false
    @State private var message: String?
    @State private var counterparts: [StatementTransaction] = []

    init(lineId: UUID) {
        self.lineId = lineId
        _lines = Query(filter: #Predicate<StatementTransaction> { $0.id == lineId })
        _matches = Query(filter: #Predicate<ReconciliationMatch> { $0.statementTransactionId == lineId })
    }

    private var line: StatementTransaction? { lines.first }
    private var byId: [UUID: MoneyTransaction] { Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    private var suggestions: [ReconciliationMatch] {
        matches.filter { $0.status == .suggested }.sorted { ($0.isPrimary ? 1 : 0, $0.score) > ($1.isPrimary ? 1 : 0, $1.score) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let line {
                    Form {
                        statementSection(line)
                        switch line.status {
                        case .matched, .created, .skipped: resolvedSections(line)
                        case .unmatched, .suggested: openSections(line)
                        }
                    }
                } else {
                    ContentUnavailableView("Line Not Found", systemImage: "doc.questionmark")
                }
            }
            .brandScreen()
            .navigationTitle("Review Line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: line?.status) { loadCounterparts() }
            .alert("Review", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }

    // MARK: Sections

    private func statementSection(_ l: StatementTransaction) -> some View {
        Section("On the statement") {
            Text(l.originalDescription)
            LabeledContent("Amount", value: (l.direction == .moneyIn ? "+" : "−") + CurrencyMath.format(l.amountMinorUnits, currencyCode: l.currencyCode))
            LabeledContent("Date", value: l.transactionDate.formatted(date: .abbreviated, time: .omitted))
            if let p = l.postingDate { LabeledContent("Posted", value: p.formatted(date: .abbreviated, time: .omitted)) }
            LabeledContent("Kind", value: l.kind.displayName + (l.isPending ? " · Pending" : ""))
            LabeledContent("Where", value: "Page \(l.sourcePage), line \(l.sourceLine)")
        }
    }

    @ViewBuilder
    private func openSections(_ l: StatementTransaction) -> some View {
        if suggestions.isEmpty {
            Section { Text("No transaction in the app matches this line yet.").foregroundStyle(.secondary) }
        }
        ForEach(suggestions) { m in
            if let t = byId[m.transactionId] {
                Section {
                    ComparisonRows(line: l, transaction: t, methods: methods, categories: categories)
                    DisclosureGroup("Why (\(m.score)/100)") {
                        ForEach(m.reasons, id: \.self) { Text("• " + $0).font(.caption) }
                    }
                    if m.amountDifferenceMinorUnits != 0 {
                        Toggle("Change my transaction to the statement amount", isOn: $useStatementAmount)
                    }
                    Button { run { try app.statements.confirm(lineId: l.id, transactionId: t.id, useStatementAmount: useStatementAmount) } } label: {
                        Label("Confirm Match", systemImage: "checkmark.circle.fill")
                    }
                    Button(role: .destructive) { run { try app.statements.reject(matchId: m.id) } } label: {
                        Label("Not This One", systemImage: "xmark.circle")
                    }
                } header: {
                    Text(m.isAmbiguous ? "Several close matches: choose one" : (m.isPrimary ? m.strength.displayName : "Other candidate"))
                } footer: {
                    if m.amountDifferenceMinorUnits != 0 {
                        Text("The amounts differ. Confirming keeps your amount unless you turn on the switch above. The date is never changed.")
                    }
                }
            }
        }
        Section {
            NavigationLink { ChooseTransactionView(lineId: l.id) } label: { Label("Choose Another Transaction", systemImage: "list.bullet") }
            NavigationLink { NewTransactionFromLineView(lineId: l.id, forceTransfer: false) } label: {
                Label("Add as New Transaction", systemImage: "plus.circle")
            }
            if l.kind != .purchase {
                NavigationLink { NewTransactionFromLineView(lineId: l.id, forceTransfer: true) } label: {
                    Label(l.kind == .cardPayment ? "Add as Credit Card Payment" : "Add as Transfer", systemImage: "arrow.left.arrow.right")
                }
            }
            Button { run { try app.statements.skip(lineId: l.id) } } label: { Label("Skip This Line", systemImage: "forward") }
            Button { dismiss() } label: { Label("Review Later", systemImage: "clock") }
        } footer: {
            Text("Skip lines you don't track, such as a duplicate already reconciled. Card payments and transfers between your own accounts are never counted as spending.")
        }
    }

    @ViewBuilder
    private func resolvedSections(_ l: StatementTransaction) -> some View {
        Section {
            switch l.status {
            case .matched: Label("Confirmed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .created: Label("Added as a new transaction", systemImage: "plus.circle.fill").foregroundStyle(.green)
            default: Label("Skipped", systemImage: "forward.fill").foregroundStyle(.secondary)
            }
            if let id = l.matchedTransactionId, let t = byId[id] {
                ComparisonRows(line: l, transaction: t, methods: methods, categories: categories)
            }
            Button(role: .destructive) { run { try app.statements.undo(lineId: l.id) } } label: {
                Label(l.status == .created ? "Undo (deletes the added transaction)" : "Undo", systemImage: "arrow.uturn.backward")
            }
        }
        if !counterparts.isEmpty, let id = l.matchedTransactionId, byId[id]?.transactionType == .transfer {
            Section {
                ForEach(counterparts) { c in
                    Button { run { try app.statements.pairTransfer(lineId: l.id, counterpartId: c.id) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Link: \(c.originalDescription)").lineLimit(2)
                            Text(c.transactionDate.formatted(date: .abbreviated, time: .omitted) + " · "
                                 + CurrencyMath.format(c.amountMinorUnits, currencyCode: c.currencyCode))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Other side of this transfer")
            } footer: {
                Text("Found on another account's statement. Linking records one transfer backed by both statements, so the payment is never counted twice.")
            }
        }
    }

    private func loadCounterparts() {
        counterparts = (try? app.statements.transferCounterparts(lineId: lineId)) ?? []
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); loadCounterparts() } catch { message = error.localizedDescription }
    }
}

/// Statement line and app transaction side by side; differences are highlighted.
struct ComparisonRows: View {
    let line: StatementTransaction
    let transaction: MoneyTransaction
    let methods: [PaymentMethod]
    let categories: [SpendingCategory]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("Statement").font(.caption.weight(.semibold))
                Text("In the app").font(.caption.weight(.semibold))
            }
            row("Date", line.transactionDate.formatted(date: .abbreviated, time: .omitted),
                transaction.transactionDate.formatted(date: .abbreviated, time: .omitted),
                differs: !Calendar.current.isDate(line.transactionDate, inSameDayAs: transaction.transactionDate))
            row("Amount", CurrencyMath.format(line.amountMinorUnits, currencyCode: line.currencyCode),
                CurrencyMath.format(transaction.amountMinorUnits, currencyCode: transaction.currencyCode),
                differs: line.amountMinorUnits != transaction.amountMinorUnits)
            row("Merchant", line.originalDescription, transaction.merchant ?? transaction.title,
                differs: StatementMerchantNormalizer.similarity(line.normalizedMerchant, StatementMerchantNormalizer.normalize(transaction.merchant ?? transaction.title)) < 0.6)
            row("Type", line.kind.displayName, transaction.transactionType.displayName, differs: false)
            row("Paid with", "—", transaction.paymentMethodId.flatMap { id in methods.first { $0.id == id }?.name } ?? "Not set",
                differs: transaction.paymentMethodId == nil)
            if transaction.transactionType.categoryKind != nil {
                row("Category", "—", transaction.categoryId.flatMap { id in categories.first { $0.id == id }?.name } ?? "Uncategorized", differs: false)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ a: String, _ b: String, differs: Bool) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(a).lineLimit(2)
            Text(b).lineLimit(2).foregroundStyle(differs ? .orange : .primary)
        }
    }
}

/// Pick any nearby transaction (±10 days, same currency, compatible direction) for a line.
struct ChooseTransactionView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let lineId: UUID
    @Query(sort: \MoneyTransaction.transactionDate, order: .reverse) private var transactions: [MoneyTransaction]
    @State private var message: String?
    @State private var search = ""

    private var candidates: [MoneyTransaction] {
        guard let line = try? app.statements.fetchLine(id: lineId),
              let statement = try? app.statements.fetchStatement(id: line.statementId),
              let account = try? app.statements.financialAccount(id: statement.accountId) else { return [] }
        let blocked = (try? app.statements.blockedTransactionIds(forAccount: account.id, excludingLine: line.id)) ?? []
        let service = StatementReconciliationService()
        let ra = ReconciliationAccount(paymentMethodId: account.linkedPaymentMethodId, isCreditCard: account.accountType == .creditCard, displayName: account.nickname)
        return transactions.filter { t in
            t.currencyCode == line.currencyCode && !blocked.contains(t.id)
                && abs(service.calendarDays(from: t.transactionDate, to: line.transactionDate)) <= 10
                && service.directionCompatibility(line: line.input, transaction: t.record, account: ra) != nil
                && (search.isEmpty || (t.merchant ?? t.title).localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            if candidates.isEmpty { Text("No transactions within 10 days fit this line.").foregroundStyle(.secondary) }
            ForEach(candidates) { t in
                Button {
                    do { try app.statements.confirm(lineId: lineId, transactionId: t.id); dismiss() }
                    catch { message = error.localizedDescription }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.merchant ?? t.title).foregroundStyle(.primary)
                            Text(t.transactionDate.formatted(date: .abbreviated, time: .omitted) + " · " + t.transactionType.displayName)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(CurrencyMath.format(t.amountMinorUnits, currencyCode: t.currencyCode)).monospacedDigit().foregroundStyle(.primary)
                    }
                }
            }
        }
        .searchable(text: $search)
        .brandScreen()
        .navigationTitle("Choose Transaction")
        .alert("Can't Confirm", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
}

/// Add a statement line as a new transaction. Starts from a suggestion the user can change.
struct NewTransactionFromLineView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let lineId: UUID
    let forceTransfer: Bool
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query(filter: #Predicate<PaymentMethod> { $0.isActive }, sort: \PaymentMethod.name) private var methods: [PaymentMethod]
    @State private var decision: NewTransactionDecision?
    @State private var message: String?
    @State private var insight: DescriptionInsight?

    var body: some View {
        Form {
            if let insight, let binding = Binding($decision) {
                Section {
                    Text(insight.explanation).font(.subheadline)
                    if binding.wrappedValue.type != .transfer, insight.merchantName != (binding.wrappedValue.merchant ?? "") {
                        Button("Use the name “\(insight.merchantName)”") {
                            binding.wrappedValue.merchant = insight.merchantName
                            binding.wrappedValue.title = insight.merchantName
                        }
                    }
                    if let name = insight.categoryName, let kind = binding.wrappedValue.type.categoryKind,
                       let c = categories.first(where: { $0.kind == kind && $0.name == name }), binding.wrappedValue.categoryId != c.id {
                        Button("Use the category “\(name)”") { binding.wrappedValue.categoryId = c.id }
                    }
                } header: {
                    Text("Suggestion")
                } footer: {
                    Text(insight.source == .onDeviceModel
                         ? "From Apple Intelligence on this iPhone. Nothing is sent anywhere. Check it before using it."
                         : "From TallySeam's built-in rules, on this iPhone.")
                }
            }
            if let binding = Binding($decision) {
                Section {
                    Picker("Type", selection: binding.type) {
                        ForEach([TransactionType.expense, .income, .transfer]) { Text($0.displayName).tag($0) }
                    }
                    TextField("Title", text: binding.title)
                    if binding.wrappedValue.type != .transfer {
                        TextField("Merchant", text: Binding(get: { binding.wrappedValue.merchant ?? "" }, set: { binding.wrappedValue.merchant = $0 }))
                        Toggle("Refund", isOn: binding.isRefund)
                    }
                }
                if let kind = binding.wrappedValue.type.categoryKind {
                    Section {
                        Picker("Category", selection: binding.categoryId) {
                            Text("Uncategorized").tag(UUID?.none)
                            ForEach(categories.filter { $0.kind == kind }) { Text($0.name).tag(Optional($0.id)) }
                        }
                    } footer: {
                        if binding.wrappedValue.categorySuggested { Text("Suggested from the merchant name. Change it if it's wrong.") }
                    }
                }
                Section(binding.wrappedValue.type == .transfer ? "Accounts" : "Payment") {
                    Picker(binding.wrappedValue.type == .transfer ? "From" : "Paid with", selection: binding.paymentMethodId) {
                        Text("Not specified").tag(UUID?.none)
                        ForEach(methods) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if binding.wrappedValue.type == .transfer {
                        Picker("To", selection: binding.transferDestinationPaymentMethodId) {
                            Text("Not specified").tag(UUID?.none)
                            ForEach(methods) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
                Section {
                    Button("Add Transaction") { save() }
                } footer: {
                    Text(binding.wrappedValue.type == .transfer
                         ? "A transfer moves money between your own accounts (for example paying a credit card) and is never counted as spending."
                         : "Dated with the statement's transaction date. The original statement text is kept in the notes.")
                }
            } else {
                ProgressView()
            }
        }
        .brandScreen()
        .navigationTitle(forceTransfer ? "Add Transfer" : "Add Transaction")
        .task {
            load()
            await loadInsight()
        }
        .alert("Can't Add", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func load() {
        guard decision == nil else { return }
        do {
            var d = try app.statements.proposedNewTransaction(
                lineId: lineId, categories: categories.map { CategoryOption(id: $0.id, name: $0.name, kind: $0.kind) },
                paymentMethods: methods, suggester: app.categorySuggester)
            if forceTransfer, d.type != .transfer {
                let accountPM = d.paymentMethodId
                d.type = .transfer; d.categoryId = nil; d.isRefund = false; d.merchant = nil
                if let line = try? app.statements.fetchLine(id: lineId), line.direction == .moneyIn {
                    d.paymentMethodId = nil; d.transferDestinationPaymentMethodId = accountPM
                }
            }
            decision = d
        } catch { message = error.localizedDescription }
    }

    private func loadInsight() async {
        guard insight == nil, let line = try? app.statements.fetchLine(id: lineId) else { return }
        let description = line.originalDescription, kind = line.kind
        let names = categories.filter { $0.kind == .expense }.map(\.name)
        insight = await DescriptionAssistantFactory.make().insight(for: description, kind: kind, categoryNames: names)
    }

    private func save() {
        guard let decision else { return }
        do { try app.statements.createTransaction(lineId: lineId, decision: decision); dismiss() }
        catch { message = error.localizedDescription }
    }
}

/// Preview, then confirm all strong, unambiguous, exact-amount matches at once.
struct BulkConfirmView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let statementId: UUID
    @Query private var transactions: [MoneyTransaction]
    @State private var items: [BulkConfirmItem] = []
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        if let line = try? app.statements.fetchLine(id: item.lineId), let t = transactions.first(where: { $0.id == item.transactionId }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.originalDescription).lineLimit(1)
                                Text("→ \(t.merchant ?? t.title), \(t.transactionDate.formatted(date: .abbreviated, time: .omitted)), "
                                     + CurrencyMath.format(t.amountMinorUnits, currencyCode: t.currencyCode))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text(items.isEmpty ? "No strong matches are waiting." : "Only strong matches with the same amount and a single clear candidate are included. Nothing is changed except marking these lines confirmed.")
                }
            }
            .brandScreen()
            .navigationTitle("Confirm \(items.count) Matches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm All") {
                        do { try app.statements.bulkConfirm(items); dismiss() } catch { message = error.localizedDescription }
                    }
                    .disabled(items.isEmpty)
                }
            }
            .task { items = (try? app.statements.bulkConfirmCandidates(statementId: statementId)) ?? [] }
            .alert("Can't Confirm", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }
}
