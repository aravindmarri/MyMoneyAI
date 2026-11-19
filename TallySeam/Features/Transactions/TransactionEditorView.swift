import SwiftUI
import SwiftData

/// What the editor sheet is doing. Duplicates open as a new, unsaved draft; nothing is saved until the user taps Save.
enum TransactionEditorRoute: Identifiable {
    case new(currencyCode: String)
    case edit(TransactionRecord)
    case duplicate(TransactionRecord)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let r): "edit-\(r.id)"
        case .duplicate(let r): "dup-\(r.id)"
        }
    }
    var title: String {
        switch self {
        case .new: "New Transaction"
        case .edit: "Edit Transaction"
        case .duplicate: "Duplicate"
        }
    }
    var draft: TransactionDraft {
        switch self {
        case .new(let code): TransactionDraft(currencyCode: code)
        case .edit(let r): TransactionDraft(editing: r)
        case .duplicate(let r): TransactionDraft.duplicating(r)
        }
    }
}

struct TransactionEditorView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query(sort: \PaymentMethod.createdAt) private var methods: [PaymentMethod]

    @State private var draft: TransactionDraft
    @State private var errorMessage: String?
    @State private var addingMethodFor: MethodSlot?
    @FocusState private var amountFocused: Bool
    private let navigationTitle: String

    init(route: TransactionEditorRoute) {
        _draft = State(initialValue: route.draft)
        navigationTitle = route.title
    }

    private var categoryKinds: [UUID: CategoryKind] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.kind) })
    }
    private var applicableCategories: [SpendingCategory] {
        guard let kind = draft.type.categoryKind else { return [] }
        return categories.filter { $0.kind == kind }
    }
    /// Active methods, plus any inactive one already selected (so editing old records doesn't lose it).
    private var selectableMethods: [PaymentMethod] {
        methods.filter { $0.isActive || $0.id == draft.paymentMethodId || $0.id == draft.transferDestinationPaymentMethodId }
    }
    private var showRepaymentWarning: Bool {
        let name = draft.categoryId.flatMap { id in categories.first { $0.id == id }?.name }
        return CreditCardRepaymentDetector.shouldWarn(type: draft.type, title: draft.title, merchant: draft.merchant, categoryName: name)
    }
    private var isRepaymentTransfer: Bool {
        let dest = draft.transferDestinationPaymentMethodId.flatMap { id in methods.first { $0.id == id }?.type }
        return CreditCardRepaymentDetector.isRepaymentTransfer(type: draft.type, destinationType: dest)
    }

    var body: some View {
        NavigationStack {
            form
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .onChange(of: draft.type) { _, newType in typeChanged(to: newType) }
                .alert("Can't Save", isPresented: errorBinding) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
                .onAppear {
                    if draft.editingId == nil && draft.amountText.isEmpty { amountFocused = true }
                    applyLastUsedMethod()
                }
                .sheet(item: $addingMethodFor) { slot in
                    PaymentMethodEditorView(route: .new) { id in
                        switch slot {
                        case .source: draft.paymentMethodId = id
                        case .destination: draft.transferDestinationPaymentMethodId = id
                        }
                    }
                }
        }
    }

    private var form: some View {
        Form {
            typeSection
            amountSection
            if showRepaymentWarning { repaymentWarningSection }
            detailsSection
            if draft.type.categoryKind != nil { categorySection }
            paymentSection
            notesSection
        }
    }

    // MARK: Sections

    private var typeSection: some View {
        Section {
            Picker("Type", selection: $draft.type) {
                ForEach(TransactionType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var amountSection: some View {
        Section("Amount") {
            HStack {
                TextField("0.00", text: $draft.amountText)
                    .keyboardType(.decimalPad)
                    .font(.largeTitle.weight(.semibold).monospacedDigit())
                    .focused($amountFocused)
                    .accessibilityLabel("Amount")
                Picker("Currency", selection: $draft.currencyCode) {
                    ForEach(CurrencyMath.supportedCodes, id: \.self) { code in
                        Text(code).tag(code)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if draft.type == .income || draft.type == .expense {
                Toggle(refundLabel, isOn: $draft.isRefund)
            }
        }
    }

    private var refundLabel: String {
        draft.type == .expense ? "Refund (reduces spending)" : "Reversal (reduces income)"
    }

    private var repaymentWarningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Looks like a credit-card payment", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Card purchases are already counted as expenses when you make them. Recording the card payment as an expense would count that spending twice.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Record as Transfer Instead", action: convertToTransfer)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
            .padding(.vertical, 4)
        }
    }

    private var detailsSection: some View {
        Section {
            TextField("Title", text: $draft.title)
            TextField("Merchant (optional)", text: $draft.merchant)
            DatePicker("Date", selection: $draft.date, displayedComponents: .date)
            if draft.type == .income || draft.type == .expense {
                Picker("Counts in", selection: $draft.countedMonthOffset) {
                    ForEach(Array(CountedMonth.allowedOffsets).reversed(), id: \.self) { offset in
                        Text(countedMonthLabel(offset)).tag(offset)
                    }
                }
                if draft.countedMonthOffset == 0, draft.type == .income, isNearMonthEnd {
                    Button("Pay for next month? Count it in \(monthName(offset: 1))") {
                        withAnimation { draft.countedMonthOffset = 1 }
                    }
                    .font(.footnote)
                }
            }
        } header: {
            Text("Details")
        } footer: {
            if draft.countedMonthOffset != 0, draft.type == .income || draft.type == .expense {
                Text("Counted in \(monthName(offset: draft.countedMonthOffset))'s totals, budgets and reports. It stays dated \(draft.date.formatted(date: .abbreviated, time: .omitted)) in your transaction list.")
            }
        }
    }

    /// The last 7 days of the date's month, when an early salary or rent payment is likely.
    private var isNearMonthEnd: Bool {
        let cal = Calendar.current
        let end = cal.monthRange(containing: draft.date).end
        return (cal.dateComponents([.day], from: cal.startOfDay(for: draft.date), to: end).day ?? 99) <= 7
    }

    private func monthName(offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .month, value: offset, to: draft.date) ?? draft.date
        return d.formatted(.dateTime.month(.wide))
    }

    private func countedMonthLabel(_ offset: Int) -> String {
        switch offset {
        case 0: "\(monthName(offset: 0)) (date's month)"
        case 1: "\(monthName(offset: 1)) (next month)"
        default: "\(monthName(offset: offset)) (previous month)"
        }
    }

    private var categorySection: some View {
        Section("Category") {
            Picker("Category", selection: $draft.categoryId) {
                Text("Uncategorized").tag(UUID?.none)
                ForEach(applicableCategories) { (c: SpendingCategory) in
                    Label(c.name, systemImage: c.symbol).tag(UUID?.some(c.id))
                }
            }
        }
    }

    private var paymentSection: some View {
        Section(draft.type == .transfer ? "Accounts" : "Payment") {
            methodPicker(paymentLabel, selection: $draft.paymentMethodId)
            if draft.type == .transfer {
                methodPicker("To", selection: $draft.transferDestinationPaymentMethodId)
            }
            Button {
                addingMethodFor = draft.type == .transfer && draft.paymentMethodId != nil ? .destination : .source
            } label: {
                Label(selectableMethods.isEmpty ? "Add a Card or Cash" : "Add Payment Method", systemImage: "plus.circle")
            }
            .font(.subheadline)
            if draft.type == .transfer {
                Text(transferNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transferNote: String {
        isRepaymentTransfer
            ? "Credit-card payment: not counted as spending, because the purchases were already recorded."
            : "Transfers move money between your own accounts and are never counted as income or spending."
    }

    private func methodPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("Not specified").tag(UUID?.none)
            ForEach(selectableMethods) { (m: PaymentMethod) in
                Text(Self.label(m)).tag(UUID?.some(m.id))
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .lineLimit(3...6)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: save)
                .disabled(draft.amountText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    // MARK: Actions

    /// For a brand-new transaction, preselect the payment method used most recently for this type.
    private func applyLastUsedMethod() {
        guard draft.editingId == nil, draft.paymentMethodId == nil, draft.receiptId == nil, draft.amountText.isEmpty,
              let records = try? app.transactions.allRecords() else { return }
        let activeIds = Set(methods.filter(\.isActive).map(\.id))
        draft.paymentMethodId = records
            .filter { $0.transactionType == draft.type && $0.paymentMethodId.map(activeIds.contains) == true }
            .max { ($0.transactionDate, $0.createdAt) < ($1.transactionDate, $1.createdAt) }?
            .paymentMethodId
    }

    private func typeChanged(to newType: TransactionType) {
        if let c = draft.categoryId, categoryKinds[c] != newType.categoryKind { draft.categoryId = nil }
        if newType != .income && newType != .expense { draft.isRefund = false }
    }

    private func convertToTransfer() {
        withAnimation {
            draft.type = .transfer
            draft.categoryId = nil
            draft.isRefund = false
        }
    }

    private var paymentLabel: String {
        switch draft.type {
        case .transfer: "From"
        case .income: "Received to"
        default: "Paid with"
        }
    }

    private static func label(_ m: PaymentMethod) -> String {
        var s = m.name
        if let l = m.lastFourDigits { s += " •••• \(l)" }
        if !m.isActive { s += " (inactive)" }
        return s
    }

    private func save() {
        do {
            try app.transactions.save(draft, categoryKinds: categoryKinds)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Which account picker a newly added payment method should fill.
private enum MethodSlot: String, Identifiable {
    case source, destination
    var id: String { rawValue }
}
