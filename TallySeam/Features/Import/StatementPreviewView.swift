import SwiftUI
import SwiftData

/// Check and correct what was read from a statement: document type, account, period, totals and
/// every transaction line. Nothing here is saved to the database.
struct StatementPreviewView: View {
    @Environment(AppContainer.self) private var app
    @Binding var document: ImportedDocument
    @Query(filter: #Predicate<PaymentMethod> { $0.isActive }, sort: \PaymentMethod.name) private var accounts: [PaymentMethod]
    @State private var editingLine: StatementLineEditorRoute?
    @State private var saveAccountId: UUID?
    @State private var savedStatementId: UUID?
    @State private var duplicateOf: ImportedStatement?
    @State private var saveError: String?

    init(document: Binding<ImportedDocument>) { _document = document }

    private var preview: Binding<StatementPreview> {
        Binding(get: {
            if case .statement(let p) = document.content { return p }
            return StatementPreview(classification: DocumentClassification(kind: .unknown, reasons: [], scores: [:]), kind: .unknown,
                                    header: StatementHeader(currencyCode: CurrencyMath.defaultCode),
                                    parse: StatementParseResult(lines: [], issues: []), pageCount: 0, usedOCR: false,
                                    text: DocumentText(pages: []))
        }, set: { document.content = .statement($0) })
    }

    var body: some View {
        let p = preview.wrappedValue
        Form {
            documentSection(p)
            accountSection
            periodSection
            amountsSection(p)
            checkSection(p)
            linesSection(p)
            if !p.parse.issues.isEmpty { issuesSection(p) }
            Section {
                NavigationLink("View Extracted Text") { ExtractedTextView(text: p.text) }
            }
            saveSection(p)
        }
        .brandScreen()
        .navigationTitle(p.header.institution ?? "Statement")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: p.kind) { _, _ in reparse() }
        .onChange(of: p.header.periodEnd) { _, _ in reparse() }
        .onChange(of: p.header.currencyCode) { _, _ in reparse() }
        .navigationDestination(item: $savedStatementId) { id in StatementDetailView(statementId: id) }
        .onAppear {
            duplicateOf = try? app.statements.duplicate(fingerprint: document.fingerprint)
            if saveAccountId == nil { saveAccountId = matchingAccountId }
        }
        .alert("Can't Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(saveError ?? "") }
        .sheet(item: $editingLine) { route in
            StatementLineEditorView(route: route, currencyCode: p.header.currencyCode, isCard: p.kind == .creditCardStatement) { line in
                apply(line, replacing: route)
            }
        }
    }

    // MARK: Sections

    private func documentSection(_ p: StatementPreview) -> some View {
        Section {
            Picker("Document type", selection: preview.kind) {
                ForEach(FinancialDocumentKind.allCases) { Text($0.displayName).tag($0) }
            }
            LabeledContent("File", value: document.filename)
            LabeledContent("Pages", value: "\(p.pageCount)" + (p.usedOCR ? " (some read with OCR)" : ""))
        } header: {
            Text("Document")
        } footer: {
            if p.classification.kind == .unknown {
                Text("The document type couldn't be recognised. Choose it above.")
            } else {
                Text("Suggested “\(p.classification.kind.displayName)” because it mentions: \(p.classification.reasons.prefix(5).joined(separator: ", ")). Please confirm.")
            }
        }
    }

    private var accountSection: some View {
        Section {
            TextField("Bank or card issuer", text: Binding(get: { preview.wrappedValue.header.institution ?? "" },
                                                            set: { preview.wrappedValue.header.institution = $0.isEmpty ? nil : $0 }))
            Picker("Account type", selection: preview.header.accountType) {
                ForEach(StatementAccountType.allCases) { Text($0.displayName).tag($0) }
            }
            TextField("Last 4 digits", text: Binding(get: { preview.wrappedValue.header.lastFour ?? "" },
                                                     set: { v in
                                                         let digits = String(v.filter(\.isNumber).prefix(4))
                                                         preview.wrappedValue.header.lastFour = digits.isEmpty ? nil : digits
                                                     }))
                .keyboardType(.numberPad)
            Picker("Currency", selection: preview.header.currencyCode) {
                ForEach(Array(Set(CurrencyMath.supportedCodes + [preview.wrappedValue.header.currencyCode])).sorted(), id: \.self) { Text($0).tag($0) }
            }
            if !accounts.isEmpty {
                LabeledContent("Matches account") {
                    Text(matchingAccountName ?? "None yet").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Only the last 4 digits of an account or card number are kept. You'll link the statement to one of your accounts before anything is saved.")
        }
    }

    /// A payment method whose last four digits or name matches the statement, as a hint.
    private var matchingAccountName: String? {
        matchingAccountId.flatMap { id in accounts.first { $0.id == id }?.name }
    }

    private var matchingAccountId: UUID? {
        let h = preview.wrappedValue.header
        if let four = h.lastFour, let m = accounts.first(where: { $0.lastFourDigits == four }) { return m.id }
        if let inst = h.institution?.lowercased(), let m = accounts.first(where: { $0.name.lowercased().contains(inst) }) { return m.id }
        return nil
    }

    @ViewBuilder
    private func saveSection(_ p: StatementPreview) -> some View {
        Section {
            if let dup = duplicateOf {
                Label("This exact file was already imported on \(dup.importedAt.formatted(date: .abbreviated, time: .omitted)).",
                      systemImage: "doc.on.doc").foregroundStyle(.orange)
                NavigationLink("Open the Saved Statement") { StatementDetailView(statementId: dup.id) }
            } else {
                Picker("Statement account", selection: $saveAccountId) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(accounts) { m in
                        Text(m.lastFourDigits.map { "\(m.name) •••• \($0)" } ?? m.name).tag(Optional(m.id))
                    }
                }
                Button("Save & Find Matches") { save(p) }
                    .disabled(saveAccountId == nil || !p.kind.isStatement || p.parse.lines.isEmpty)
            }
        } header: {
            Text("Match with your transactions")
        } footer: {
            if accounts.isEmpty {
                Text("Add this bank account or card in Settings → Payment Methods first, so the statement can be linked to it.")
            } else if !p.kind.isStatement {
                Text("Choose “Bank statement” or “Credit card statement” as the document type to match it.")
            } else {
                Text("Saves the statement and suggests which of your transactions each line matches. Nothing in your transactions is changed.")
            }
        }
    }

    private func save(_ p: StatementPreview) {
        do {
            let s = try app.statements.saveStatement(p, filename: document.filename, fingerprint: document.fingerprint,
                                                     paymentMethodId: saveAccountId, config: ReconciliationPreferences.config())
            duplicateOf = s
            savedStatementId = s.id
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var periodSection: some View {
        Section("Statement period") {
            OptionalDateRow(title: "From", date: preview.header.periodStart)
            OptionalDateRow(title: "To", date: preview.header.periodEnd)
            if preview.wrappedValue.kind == .creditCardStatement {
                OptionalDateRow(title: "Payment due", date: preview.header.paymentDueDate)
            }
        }
    }

    private func amountsSection(_ p: StatementPreview) -> some View {
        let code = p.header.currencyCode
        return Section {
            OptionalMoneyRow(title: p.kind == .creditCardStatement ? "Previous balance" : "Opening balance", value: preview.header.openingBalance, currencyCode: code)
            OptionalMoneyRow(title: p.kind == .creditCardStatement ? "New balance" : "Closing balance", value: preview.header.closingBalance, currencyCode: code)
            if p.kind == .creditCardStatement {
                OptionalMoneyRow(title: "Payments and credits", value: preview.header.totalPaymentsAndCredits, currencyCode: code)
                OptionalMoneyRow(title: "Purchases", value: preview.header.totalPurchases, currencyCode: code)
                OptionalMoneyRow(title: "Fees", value: preview.header.totalFees, currencyCode: code)
                OptionalMoneyRow(title: "Interest", value: preview.header.totalInterest, currencyCode: code)
                OptionalMoneyRow(title: "Minimum payment", value: preview.header.minimumPayment, currencyCode: code)
            } else {
                OptionalMoneyRow(title: "Total deposits", value: preview.header.totalDeposits, currencyCode: code)
                OptionalMoneyRow(title: "Total withdrawals", value: preview.header.totalWithdrawals, currencyCode: code)
            }
        } header: {
            Text("Statement totals")
        } footer: {
            Text("Read from the statement's summary. Tap a value to correct it.")
        }
    }

    private func checkSection(_ p: StatementPreview) -> some View {
        let code = p.header.currencyCode
        return Section {
            LabeledContent("Money in (read)", value: CurrencyMath.format(p.parse.totalIn, currencyCode: code))
            LabeledContent("Money out (read)", value: CurrencyMath.format(p.parse.totalOut, currencyCode: code))
            if p.parse.lines.contains(where: \.isPending) {
                LabeledContent("Pending", value: "\(p.parse.lines.filter(\.isPending).count)")
            }
            let low = p.parse.lines.filter { $0.confidence == .low }.count
            if low > 0 { LabeledContent("Low confidence", value: "\(low)") }
        } header: {
            Text("What was read")
        } footer: {
            Text("Compare these with the statement totals above. Balance checks and matching come in later updates.")
        }
    }

    private func linesSection(_ p: StatementPreview) -> some View {
        Section("Transactions (\(p.parse.lines.count))") {
            if p.parse.lines.isEmpty {
                Text("No transaction lines were found.").foregroundStyle(.secondary)
            }
            ForEach(p.parse.lines) { line in
                Button { editingLine = .line(line) } label: {
                    StatementLineRow(line: line, currencyCode: p.header.currencyCode)
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private func issuesSection(_ p: StatementPreview) -> some View {
        Section {
            ForEach(p.parse.issues) { issue in
                Button { editingLine = .issue(issue) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.text).font(.callout.monospaced()).lineLimit(2).foregroundStyle(.primary)
                        Text("Page \(issue.page), line \(issue.line): \(issue.reason). Tap to enter it by hand.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Couldn't read (\(p.parse.issues.count))")
        } footer: {
            Text("These lines looked like transactions but couldn't be read. They're kept here instead of being dropped.")
        }
    }

    // MARK: Actions

    private func reparse() {
        preview.wrappedValue = StatementImportService.reparse(preview.wrappedValue, calendar: .current)
    }

    private func apply(_ line: ParsedStatementLine, replacing route: StatementLineEditorRoute) {
        var p = preview.wrappedValue
        switch route {
        case .line(let old):
            if let i = p.parse.lines.firstIndex(where: { $0.id == old.id }) { p.parse.lines[i] = line }
        case .issue(let issue):
            p.parse.issues.removeAll { $0.id == issue.id }
            p.parse.lines.append(line)
            p.parse.lines.sort { ($0.page, $0.line) < ($1.page, $1.line) }
        }
        preview.wrappedValue = p
    }
}

struct StatementLineRow: View {
    let line: ParsedStatementLine
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.description).lineLimit(2)
                Spacer()
                Text((line.direction == .moneyIn ? "+" : "−") + CurrencyMath.format(line.amountMinorUnits, currencyCode: currencyCode))
                    .monospacedDigit()
                    .foregroundStyle(line.direction == .moneyIn ? Theme.income : .primary)
            }
            HStack(spacing: 6) {
                Text(line.transactionDate.formatted(date: .abbreviated, time: .omitted))
                if let posted = line.postingDate { Text("posted \(posted.formatted(.dateTime.month(.abbreviated).day()))") }
                Text("· \(line.kind.displayName)")
                if line.isPending { Text("· Pending").foregroundStyle(.orange) }
                if line.isEdited { Text("· Edited") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if line.confidence < .high, let note = line.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A date that may be missing from the statement. Shows "Not found" with a button to set it.
struct OptionalDateRow: View {
    let title: String
    @Binding var date: Date?

    var body: some View {
        if let value = date {
            HStack {
                DatePicker(title, selection: Binding(get: { value }, set: { date = $0 }), displayedComponents: .date)
                Button { date = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear \(title)")
            }
        } else {
            LabeledContent(title) {
                Button("Not found · Set") { date = Calendar.current.startOfDay(for: .now) }
            }
        }
    }
}

/// An amount that may be missing. Typed as text; "-" allowed for negative balances.
struct OptionalMoneyRow: View {
    let title: String
    @Binding var value: Int64?
    let currencyCode: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField("Not found", text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .focused($focused)
                .onAppear { text = display }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onSubmit(commit)
        }
    }

    private var display: String {
        guard let v = value else { return "" }
        return (v < 0 ? "-" : "") + CSVTransactionExporter.plainAmount(abs(v), currencyCode: currencyCode)
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        value = t.isEmpty ? nil : CSVAmountParser.parse(t, currencyCode: currencyCode)
        text = display
    }
}

struct ExtractedTextView: View {
    let text: DocumentText

    var body: some View {
        List {
            ForEach(text.pages, id: \.index) { page in
                Section("Page \(page.index + 1)" + (page.source == .ocr ? " (OCR)" : "")) {
                    ForEach(Array(page.lines.enumerated()), id: \.offset) { n, line in
                        HStack(alignment: .top) {
                            Text("\(n + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .brandScreen()
        .navigationTitle("Extracted Text")
    }
}

enum StatementLineEditorRoute: Identifiable {
    case line(ParsedStatementLine)
    case issue(StatementParseIssue)
    var id: UUID {
        switch self {
        case .line(let l): l.id
        case .issue(let i): i.id
        }
    }
}

/// Correct a read line, or type in a line the parser couldn't read.
struct StatementLineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let route: StatementLineEditorRoute
    let currencyCode: String
    let isCard: Bool
    let onSave: (ParsedStatementLine) -> Void

    @State private var date = Date()
    @State private var hasPostingDate = false
    @State private var postingDate = Date()
    @State private var description = ""
    @State private var amountText = ""
    @State private var direction: StatementDirection = .moneyOut
    @State private var kind: StatementLineKind = .purchase
    @State private var isPending = false

    init(route: StatementLineEditorRoute, currencyCode: String, isCard: Bool, onSave: @escaping (ParsedStatementLine) -> Void) {
        self.route = route; self.currencyCode = currencyCode; self.isCard = isCard; self.onSave = onSave
        switch route {
        case .line(let l):
            _date = State(initialValue: l.transactionDate)
            _hasPostingDate = State(initialValue: l.postingDate != nil)
            _postingDate = State(initialValue: l.postingDate ?? l.transactionDate)
            _description = State(initialValue: l.description)
            _amountText = State(initialValue: CSVTransactionExporter.plainAmount(l.amountMinorUnits, currencyCode: currencyCode))
            _direction = State(initialValue: l.direction)
            _kind = State(initialValue: l.kind)
            _isPending = State(initialValue: l.isPending)
        case .issue(let i):
            let tokens = MoneyText.tokens(in: i.text, currencyCode: currencyCode)
            _description = State(initialValue: i.text)
            if let t = tokens.last { _amountText = State(initialValue: CSVTransactionExporter.plainAmount(abs(t.value), currencyCode: currencyCode)) }
            _kind = State(initialValue: isCard ? .purchase : .withdrawal)
        }
    }

    private var amount: Int64? { CSVAmountParser.parse(amountText, currencyCode: currencyCode).map(abs) }

    var body: some View {
        NavigationStack {
            Form {
                if case .issue(let i) = route {
                    Section("Original line") { Text(i.text).font(.callout.monospaced()) }
                }
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Toggle("Posting date", isOn: $hasPostingDate)
                    if hasPostingDate { DatePicker("Posted", selection: $postingDate, displayedComponents: .date) }
                    TextField("Description", text: $description, axis: .vertical)
                }
                Section {
                    TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                    Picker("Direction", selection: $direction) {
                        Text(isCard ? "Charge (money out)" : "Withdrawal (money out)").tag(StatementDirection.moneyOut)
                        Text(isCard ? "Payment or credit (money in)" : "Deposit (money in)").tag(StatementDirection.moneyIn)
                    }
                    Picker("Kind", selection: $kind) {
                        ForEach(StatementLineKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Pending", isOn: $isPending)
                }
            }
            .brandScreen()
            .navigationTitle(routeIsIssue ? "Enter Line" : "Edit Line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                        .disabled((amount ?? 0) == 0 || description.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var routeIsIssue: Bool { if case .issue = route { true } else { false } }

    private func save() {
        guard let amount, amount > 0 else { return }
        let base: (id: UUID, page: Int, line: Int, balance: Int64?) = {
            switch route {
            case .line(let l): (l.id, l.page, l.line, l.runningBalance)
            case .issue(let i): (UUID(), i.page, i.line, nil)
            }
        }()
        onSave(ParsedStatementLine(id: base.id, page: base.page, line: base.line, transactionDate: date,
                                   postingDate: hasPostingDate ? postingDate : nil,
                                   description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                                   amountMinorUnits: amount, direction: direction, runningBalance: base.balance, kind: kind,
                                   isPending: isPending, confidence: .high, note: nil, isEdited: true))
        dismiss()
    }
}
