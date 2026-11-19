import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \MoneyTransaction.transactionDate, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query private var settings: [AppSettings]

    @State private var filter = TransactionFilter()
    @State private var showFilters = false
    @State private var editorRoute: TransactionEditorRoute?
    @State private var pendingDelete: TransactionRecord?
    @State private var errorMessage: String?

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    private var filtered: [MoneyTransaction] {
        transactions.filter { filter.matches($0.record) }
    }

    /// Groups by calendar day, newest first.
    private func sections(_ items: [MoneyTransaction]) -> [(day: Date, items: [MoneyTransaction])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: items) { cal.startOfDay(for: $0.transactionDate) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        let categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let items = filtered
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    EmptyStateView(title: "No Transactions",
                                   systemImage: "list.bullet.rectangle",
                                   message: "Record income and expenses to see them here. Everything stays on this iPhone.",
                                   actionTitle: "Add Transaction") { editorRoute = .new(currencyCode: currency) }
                } else if items.isEmpty {
                    if filter.hasActiveFilters {
                        EmptyStateView(title: "No Matches", systemImage: "line.3.horizontal.decrease.circle",
                                       message: "No transactions match the current filters.",
                                       actionTitle: "Clear Filters") { filter = TransactionFilter(searchText: filter.searchText) }
                    } else {
                        ContentUnavailableView.search(text: filter.searchText)
                    }
                } else {
                    List {
                        ForEach(sections(items), id: \.day) { section in
                            Section(section.day.formatted(date: .abbreviated, time: .omitted)) {
                                ForEach(section.items) { t in
                                    row(t, category: t.categoryId.flatMap { categoryByID[$0] })
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Transactions")
            .searchable(text: $filter.searchText, prompt: "Merchant or title")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showFilters = true } label: {
                        Image(systemName: filter.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(filter.hasActiveFilters ? "Filters, active" : "Filters")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editorRoute = .new(currencyCode: currency) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add transaction")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                TransactionDetailView(transactionID: id)
            }
            .sheet(item: $editorRoute) { route in TransactionEditorView(route: route) }
            .sheet(isPresented: $showFilters) { TransactionFilterView(filter: $filter) }
            .confirmationDialog("Delete Transaction?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { r in
                Button("Delete", role: .destructive) { delete(r) }
            } message: { r in
                Text("\(r.title), \(CurrencyMath.format(r.amountMinorUnits, currencyCode: r.currencyCode)). This can't be undone.")
            }
            .alert("Something Went Wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func row(_ t: MoneyTransaction, category: SpendingCategory?) -> some View {
        let record = t.record
        return NavigationLink(value: t.id) {
            TransactionRow(transaction: t, category: category)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = record } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button { editorRoute = .duplicate(record) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .tint(.indigo)
        }
        .contextMenu {
            Button { editorRoute = .edit(record) } label: { Label("Edit", systemImage: "pencil") }
            Button { editorRoute = .duplicate(record) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { pendingDelete = record } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func delete(_ r: TransactionRecord) {
        do { try app.transactions.delete(id: r.id) } catch { errorMessage = error.localizedDescription }
        pendingDelete = nil
    }
}

struct TransactionFilterView: View {
    @Binding var filter: TransactionFilter
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query(sort: \PaymentMethod.createdAt) private var methods: [PaymentMethod]

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    ForEach(TransactionType.allCases) { type in
                        Toggle(isOn: Binding(get: { filter.types.contains(type) },
                                             set: { on in if on { filter.types.insert(type) } else { filter.types.remove(type) } })) {
                            Label(type.displayName, systemImage: type.symbol)
                        }
                    }
                }
                Section("Category") {
                    Picker("Category", selection: $filter.categoryId) {
                        Text("Any").tag(UUID?.none)
                        ForEach(categories) { c in Text("\(c.name) (\(c.kind.displayName))").tag(Optional(c.id)) }
                    }
                }
                Section("Payment Method") {
                    Picker("Payment method", selection: $filter.paymentMethodId) {
                        Text("Any").tag(UUID?.none)
                        ForEach(methods) { m in Text(m.name).tag(Optional(m.id)) }
                    }
                }
                Section("Date") {
                    optionalDate("From", $filter.startDate)
                    optionalDate("To", $filter.endDate)
                }
                Section {
                    Button("Clear All Filters", role: .destructive) { filter = TransactionFilter(searchText: filter.searchText) }
                        .disabled(!filter.hasActiveFilters)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func optionalDate(_ label: String, _ value: Binding<Date?>) -> some View {
        Toggle(label, isOn: Binding(get: { value.wrappedValue != nil },
                                    set: { value.wrappedValue = $0 ? Calendar.current.startOfDay(for: .now) : nil }))
        if let current = value.wrappedValue {
            DatePicker(label, selection: Binding(get: { current }, set: { value.wrappedValue = $0 }), displayedComponents: .date)
                .labelsHidden()
        }
    }
}
