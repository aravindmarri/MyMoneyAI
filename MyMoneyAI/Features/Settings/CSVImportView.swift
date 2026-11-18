import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A CSV file handed to the system file exporter.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = try CSVParser.decode(configuration.file.regularFileContents ?? Data())
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Wraps a parsed file so it can drive `.sheet(item:)`.
struct CSVImportRequest: Identifiable {
    let id = UUID()
    var table: CSVTable
}

/// Map a bank statement's columns, review every row, then add the new transactions.
struct CSVImportView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query(filter: #Predicate<PaymentMethod> { $0.isActive }, sort: \PaymentMethod.name) private var paymentMethods: [PaymentMethod]
    @Query private var settings: [AppSettings]

    let table: CSVTable
    let onFinished: (String) -> Void

    @State private var hasHeaderRow = true
    @State private var source: CSVImportSource
    @State private var mapping = CSVColumnMapping()
    @State private var options = CSVImportOptions(currencyCode: CurrencyMath.defaultCode)
    @State private var plan = CSVImportPlan(rows: [])
    @State private var includeDuplicates = false
    @State private var dateOrders: [CSVDateOrder] = []
    @State private var confirmImport = false
    @State private var errorMessage: String?
    @State private var prepared = false

    private static let previewLimit = 300

    init(table: CSVTable, onFinished: @escaping (String) -> Void) {
        self.table = table
        self.onFinished = onFinished
        let header = CSVImportSource.looksLikeHeader(table.rows.first ?? [], calendar: .current)
        _hasHeaderRow = State(initialValue: header)
        _source = State(initialValue: CSVImportSource(table: table, hasHeaderRow: header))
    }

    private var importCount: Int { plan.recordsToImport(includeDuplicates: includeDuplicates).count }

    var body: some View {
        NavigationStack {
            Form {
                fileSection
                columnsSection
                amountSection
                moreColumnsSection
                accountSection
                summarySection
                previewSection
            }
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { confirmImport = true }.disabled(!mapping.isComplete || importCount == 0)
                }
            }
            .confirmationDialog("Add \(importCount) transactions?", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("Add \(importCount) Transactions") { save() }
            } message: {
                Text("They're added to your existing data. Nothing already in the app is changed.")
            }
            .alert("Import CSV", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .onAppear(perform: prepare)
        .onChange(of: hasHeaderRow) { _, newValue in
            source = CSVImportSource(table: table, hasHeaderRow: newValue)
            mapping = source.suggestedMapping(calendar: .current, locale: .current)
            refresh()
        }
        .onChange(of: mapping) { _, _ in refresh() }
        .onChange(of: options) { _, _ in refresh() }
    }

    // MARK: Sections

    private var fileSection: some View {
        Section {
            LabeledContent("Rows", value: "\(source.rows.count)")
            Toggle("First row is column names", isOn: $hasHeaderRow)
        } footer: {
            Text("The file is read only on this iPhone.")
        }
    }

    private var columnsSection: some View {
        Section("Columns") {
            columnPicker("Date", selection: $mapping.date, required: true)
            if dateOrders.count > 1 || (dateOrders.isEmpty && mapping.date != nil) {
                Picker("Date format", selection: $mapping.dateOrder) {
                    ForEach(dateOrders.isEmpty ? CSVDateOrder.allCases : dateOrders) { Text($0.displayName).tag($0) }
                }
            }
            columnPicker("Description", selection: $mapping.description)
        }
    }

    private var amountSection: some View {
        Section {
            Picker("Amounts", selection: $mapping.amountMode) {
                ForEach(CSVAmountMode.allCases) { Text($0.displayName).tag($0) }
            }
            switch mapping.amountMode {
            case .single:
                columnPicker("Amount", selection: $mapping.amount, required: true)
                Picker("Money spent is", selection: $mapping.negativeIsExpense) {
                    Text("Negative (−12.50)").tag(true)
                    Text("Positive (12.50)").tag(false)
                }
            case .debitCredit:
                columnPicker("Debit (money out)", selection: $mapping.debit)
                columnPicker("Credit (money in)", selection: $mapping.credit)
            }
        } header: {
            Text("Amounts")
        } footer: {
            if mapping.type != nil {
                Text("The Type column decides income or expense; amounts are used as positive values.")
            } else {
                Text("Check a few rows below: spending should show as expenses.")
            }
        }
    }

    private var moreColumnsSection: some View {
        Section {
            columnPicker("Merchant", selection: $mapping.merchant)
            columnPicker("Category", selection: $mapping.category)
            columnPicker("Notes", selection: $mapping.notes)
            columnPicker("Type", selection: $mapping.type)
            if mapping.type != nil { columnPicker("Refund", selection: $mapping.refund) }
            if mapping.countedMonth != nil { columnPicker("Counts in month", selection: $mapping.countedMonth) }
        } header: {
            Text("Optional columns")
        } footer: {
            Text("Category names must match your categories. Rows without one get a suggestion from the merchant name, or stay uncategorized.")
        }
    }

    private var accountSection: some View {
        Section {
            Picker("Currency", selection: $options.currencyCode) {
                ForEach(currencyCodes, id: \.self) { Text($0).tag($0) }
            }
            Picker("Account", selection: $options.paymentMethodId) {
                Text("None").tag(UUID?.none)
                ForEach(paymentMethods) { Text($0.name).tag(Optional($0.id)) }
            }
        } header: {
            Text("Statement")
        } footer: {
            Text("The account this statement is from is set as the payment method of every imported transaction.")
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent("New", value: "\(plan.newCount)")
            LabeledContent("Already in the app", value: "\(plan.duplicateCount)")
            LabeledContent("Can't be read", value: "\(plan.invalidCount)")
            if plan.duplicateCount > 0 {
                Toggle("Also import possible duplicates", isOn: $includeDuplicates)
            }
        } header: {
            Text("Summary")
        } footer: {
            Text("A row counts as already in the app when a transaction on the same day has the same type, amount and a matching description. Rows that can't be read are skipped.")
        }
    }

    private var previewSection: some View {
        Section {
            ForEach(plan.rows.prefix(Self.previewLimit)) { row in
                CSVImportRowView(row: row, categoryName: categoryName(row.record?.categoryId), includeDuplicates: includeDuplicates)
            }
            if plan.rows.count > Self.previewLimit {
                Text("Showing the first \(Self.previewLimit) of \(plan.rows.count) rows.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Rows")
        }
    }

    private func columnPicker(_ title: String, selection: Binding<Int?>, required: Bool = false) -> some View {
        Picker(title, selection: selection) {
            Text(required ? "Choose…" : "None").tag(Int?.none)
            ForEach(source.columns.indices, id: \.self) { i in
                Text(columnLabel(i)).tag(Optional(i))
            }
        }
    }

    private func columnLabel(_ i: Int) -> String {
        let sample = source.samples(column: i, limit: 5).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return sample.isEmpty ? source.columns[i] : "\(source.columns[i]) · \(sample.prefix(20))"
    }

    private var currencyCodes: [String] {
        var codes = CurrencyMath.supportedCodes
        if !codes.contains(options.currencyCode) { codes.insert(options.currencyCode, at: 0) }
        return codes
    }

    private func categoryName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return categories.first { $0.id == id }?.name
    }

    // MARK: Actions

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        options.currencyCode = settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode
        mapping = source.suggestedMapping(calendar: .current, locale: .current)
        refresh()
    }

    private func refresh() {
        dateOrders = CSVDateParser.candidateOrders(samples: source.samples(column: mapping.date, limit: 1_000), calendar: .current, locale: .current)
        if !dateOrders.isEmpty, !dateOrders.contains(mapping.dateOrder) {
            mapping.dateOrder = dateOrders[0]   // triggers another refresh via onChange
            return
        }
        let existing = (try? app.transactions.allRecords()) ?? []
        plan = CSVTransactionImporter.plan(
            source: source, mapping: mapping, options: options,
            categories: categories.map { CategoryOption(id: $0.id, name: $0.name, kind: $0.kind) },
            existing: existing, suggester: app.categorySuggester, calendar: .current)
    }

    private func save() {
        let records = plan.recordsToImport(includeDuplicates: includeDuplicates)
        do {
            let n = try app.transactions.insertImported(records)
            let skipped = plan.rows.count - n
            dismiss()
            onFinished(skipped > 0 ? "Added \(n) transactions. \(skipped) rows were skipped." : "Added \(n) transactions.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CSVImportRowView: View {
    let row: CSVImportRow
    let categoryName: String?
    let includeDuplicates: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let r = row.record {
                    HStack {
                        Text(r.title).lineLimit(1)
                        Spacer()
                        Text(signedAmount(r)).monospacedDigit()
                            .foregroundStyle(r.transactionType == .income ? .green : .primary)
                    }
                    Text(detail(r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Row \(row.line)").foregroundStyle(.secondary)
                }
                if let note = statusNote {
                    Text(note).font(.caption).foregroundStyle(color)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch row.status {
        case .new: "plus.circle.fill"
        case .duplicate: "doc.on.doc"
        case .invalid: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch row.status {
        case .new: .green
        case .duplicate: includeDuplicates ? .green : .secondary
        case .invalid: .orange
        }
    }

    private var statusNote: String? {
        switch row.status {
        case .new: nil
        case .duplicate: includeDuplicates ? "Possible duplicate: will be imported" : "Already in the app: will be skipped"
        case .invalid(let reason): "Row \(row.line): \(reason). Will be skipped."
        }
    }

    private func signedAmount(_ r: TransactionRecord) -> String {
        let text = CurrencyMath.format(r.amountMinorUnits, currencyCode: r.currencyCode)
        return r.transactionType == .expense ? "−" + text : text
    }

    private func detail(_ r: TransactionRecord) -> String {
        var parts = [r.transactionDate.formatted(date: .abbreviated, time: .omitted), r.transactionType.displayName]
        if r.isRefund { parts.append("Refund") }
        if let categoryName { parts.append(categoryName + (row.categorySuggested ? " (suggested)" : "")) }
        return parts.joined(separator: " · ")
    }
}
