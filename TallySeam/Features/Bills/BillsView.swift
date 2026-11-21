import SwiftUI
import SwiftData

/// Recurring bills grouped by due status. Bills are reminders; only recorded payments count as spending.
struct BillsView: View {
    @Query(sort: \RecurringBill.nextDueDate) private var bills: [RecurringBill]
    @Query private var settings: [AppSettings]
    @State private var editing: BillEditorRoute?

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    var body: some View {
        Group {
            if bills.isEmpty {
                EmptyStateView(title: "No Recurring Bills", systemImage: "calendar.badge.clock",
                               message: "Bills are reminders of what you owe. They are not counted as spending until you record a payment.",
                               actionTitle: "Add Bill") { editing = .new(currencyCode: currency) }
            } else {
                list
            }
        }
        .brandScreen()
        .navigationTitle("Recurring Bills")
        .toolbar {
            Button { editing = .new(currencyCode: currency) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add bill")
        }
        .sheet(item: $editing) { BillEditorView(route: $0) }
    }

    private var list: some View {
        let now = Date.now
        let groups = BillGroup.group(bills, now: now)
        return List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.bills) { bill in
                        NavigationLink { BillDetailView(bill: bill) } label: { BillRow(bill: bill, now: now) }
                    }
                }
            }
            Section {
                Text("Upcoming bills are not counted as spending. Recording a payment adds one expense, or links one you already recorded.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct BillGroup {
    var title: String
    var bills: [RecurringBill]

    @MainActor
    static func group(_ bills: [RecurringBill], now: Date, calendar: Calendar = .current) -> [BillGroup] {
        var overdue: [RecurringBill] = [], soon: [RecurringBill] = [], later: [RecurringBill] = [], paused: [RecurringBill] = []
        for b in bills {
            switch BillSchedule.status(dueDate: b.nextDueDate, isActive: b.isActive, now: now, calendar: calendar) {
            case .overdue: overdue.append(b)
            case .dueToday, .dueSoon: soon.append(b)
            case .upcoming: later.append(b)
            case .inactive: paused.append(b)
            }
        }
        return [BillGroup(title: "Overdue", bills: overdue), BillGroup(title: "Due Soon", bills: soon),
                BillGroup(title: "Upcoming", bills: later), BillGroup(title: "Paused", bills: paused)]
            .filter { !$0.bills.isEmpty }
    }
}

struct BillRow: View {
    let bill: RecurringBill
    let now: Date

    var body: some View {
        let status = BillSchedule.status(dueDate: bill.nextDueDate, isActive: bill.isActive, now: now, calendar: .current)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bill.title).foregroundStyle(.primary)
                Label(status.label, systemImage: status.symbol)
                    .font(.caption)
                    .foregroundStyle(BillRow.color(for: status))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(bill.expectedAmountMinorUnits.map { CurrencyMath.format($0, currencyCode: bill.currencyCode) } ?? "Varies")
                    .monospacedDigit()
                Text(bill.nextDueDate, format: .dateTime.month(.abbreviated).day())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func color(for status: BillDueStatus) -> Color {
        switch status {
        case .overdue: .red
        case .dueToday, .dueSoon: .orange
        case .upcoming, .inactive: .secondary
        }
    }
}

enum BillEditorRoute: Identifiable {
    case new(currencyCode: String)
    case edit(RecurringBill)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let b): b.id.uuidString
        }
    }
}

struct BillEditorView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query(sort: \PaymentMethod.createdAt) private var methods: [PaymentMethod]
    let route: BillEditorRoute
    @State private var draft: BillDraft
    @State private var errorMessage: String?

    init(route: BillEditorRoute) {
        self.route = route
        switch route {
        case .new(let code):
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
            _draft = State(initialValue: BillDraft(currencyCode: code, nextDueDate: tomorrow))
        case .edit(let b):
            var d = BillDraft(currencyCode: b.currencyCode, nextDueDate: b.nextDueDate)
            d.editingId = b.id; d.title = b.title
            d.amountText = b.expectedAmountMinorUnits.map { TransactionDraft.editableAmount($0, currencyCode: b.currencyCode) } ?? ""
            d.categoryId = b.categoryId; d.paymentMethodId = b.paymentMethodId; d.rule = b.recurrenceRule
            d.customIntervalText = b.customIntervalDays.map(String.init) ?? ""; d.notes = b.notes ?? ""; d.isActive = b.isActive
            _draft = State(initialValue: d)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                scheduleSection
                linksSection
                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...5)
                }
                if !draft.validationErrors.isEmpty {
                    Section {
                        ForEach(draft.validationErrors, id: \.self) { e in
                            Label(e.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .brandScreen()
            .navigationTitle(draft.editingId == nil ? "New Bill" : "Edit Bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!draft.validationErrors.isEmpty)
                }
            }
            .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var detailsSection: some View {
        Section("Bill") {
            TextField("Name (e.g. Rent, Phone)", text: $draft.title)
            HStack {
                TextField("Expected amount (optional)", text: $draft.amountText).keyboardType(.decimalPad)
                Picker("Currency", selection: $draft.currencyCode) {
                    ForEach(CurrencyMath.supportedCodes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            Toggle("Active", isOn: $draft.isActive)
        }
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            DatePicker("Next due", selection: $draft.nextDueDate, displayedComponents: .date)
            Picker("Repeats", selection: $draft.rule) {
                ForEach(RecurrenceRule.allCases) { Text($0.displayName).tag($0) }
            }
            if draft.rule == .custom {
                TextField("Every how many days", text: $draft.customIntervalText).keyboardType(.numberPad)
            }
        }
    }

    private var linksSection: some View {
        Section("When Paid") {
            Picker("Category", selection: $draft.categoryId) {
                Text("Uncategorized").tag(UUID?.none)
                ForEach(categories.filter { $0.kind == .expense }) { (c: SpendingCategory) in
                    Label(c.name, systemImage: c.symbol).tag(UUID?.some(c.id))
                }
            }
            Picker("Pay with", selection: $draft.paymentMethodId) {
                Text("Not specified").tag(UUID?.none)
                ForEach(methods.filter { $0.isActive || $0.id == draft.paymentMethodId }) { (m: PaymentMethod) in
                    Text(m.name).tag(UUID?.some(m.id))
                }
            }
        }
    }

    private func save() {
        do {
            try app.bills.save(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
