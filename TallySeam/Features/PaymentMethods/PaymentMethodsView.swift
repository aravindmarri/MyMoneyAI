import SwiftUI
import SwiftData

struct PaymentMethodsView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \PaymentMethod.createdAt) private var methods: [PaymentMethod]
    @State private var editing: PaymentMethodEditorRoute?
    @State private var showSetup = false
    @State private var deleting: PaymentMethod?
    @State private var inUse: (method: PaymentMethod, count: Int)?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if methods.isEmpty {
                EmptyStateView(title: "No Payment Methods", systemImage: "creditcard",
                               message: "Add cash, debit cards and credit cards to record how you paid. Only a name and optional last four digits are stored.",
                               actionTitle: "Set Up Accounts") { showSetup = true }
            } else {
                List {
                    Section {
                        Button { showSetup = true } label: { Label("Quick Setup: Add Several", systemImage: "rectangle.stack.badge.plus") }
                    } footer: {
                        Text("Pay off a credit card from your bank as a Transfer (From: bank, To: card), so it isn't counted as spending twice.")
                    }
                    section("Active", methods.filter(\.isActive))
                    section("Inactive", methods.filter { !$0.isActive })
                }
            }
        }
        .navigationTitle("Payment Methods")
        .toolbar {
            Menu {
                Button { editing = .new } label: { Label("Add One", systemImage: "plus") }
                Button { showSetup = true } label: { Label("Quick Setup", systemImage: "rectangle.stack.badge.plus") }
            } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add payment method")
        }
        .sheet(item: $editing) { PaymentMethodEditorView(route: $0) }
        .sheet(isPresented: $showSetup) { AccountSetupView() }
        .confirmationDialog("Delete Payment Method?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { m in
            Button("Delete \(m.name)", role: .destructive) {
                do { try app.referenceData.deletePaymentMethod(id: m.id) } catch { errorMessage = error.localizedDescription }
            }
        } message: { _ in Text("No transactions use this payment method.") }
        .alert("Payment Method In Use", isPresented: Binding(get: { inUse != nil }, set: { if !$0 { inUse = nil } }), presenting: inUse) { item in
            Button("Deactivate") { deactivate(item.method) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.count) transaction(s) use “\(item.method.name)”. Deactivate it to hide it from new transactions while keeping your history.")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [PaymentMethod]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { m in
                    Button { editing = .edit(m) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(m.lastFourDigits.map { "\(m.name) •••• \($0)" } ?? m.name, systemImage: m.type.symbol)
                                .foregroundStyle(.primary)
                            Text([m.type.displayName, m.accountNickname].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { requestDelete(m) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
    }

    private func requestDelete(_ m: PaymentMethod) {
        do {
            let count = try app.referenceData.usage(ofPaymentMethod: m.id)
            if count == 0 { deleting = m } else { inUse = (m, count) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func deactivate(_ m: PaymentMethod) {
        do {
            try app.referenceData.updatePaymentMethod(m, name: m.name, type: m.type, nickname: m.accountNickname,
                                                      lastFour: m.lastFourDigits, underlyingId: m.underlyingPaymentMethodId, isActive: false)
        } catch { errorMessage = error.localizedDescription }
    }
}

enum PaymentMethodEditorRoute: Identifiable {
    case new
    case edit(PaymentMethod)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let m): m.id.uuidString
        }
    }
}

struct PaymentMethodEditorView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PaymentMethod.createdAt) private var methods: [PaymentMethod]
    let route: PaymentMethodEditorRoute
    var onSaved: ((UUID) -> Void)? = nil
    @State private var name = ""
    @State private var type: PaymentMethodType = .debitCard
    @State private var nickname = ""
    @State private var lastFour = ""
    @State private var underlyingId: UUID?
    @State private var isActive = true
    @State private var errorMessage: String?

    init(route: PaymentMethodEditorRoute, onSaved: ((UUID) -> Void)? = nil) {
        self.route = route
        self.onSaved = onSaved
        if case .edit(let m) = route {
            _name = State(initialValue: m.name); _type = State(initialValue: m.type)
            _nickname = State(initialValue: m.accountNickname ?? ""); _lastFour = State(initialValue: m.lastFourDigits ?? "")
            _underlyingId = State(initialValue: m.underlyingPaymentMethodId); _isActive = State(initialValue: m.isActive)
        }
    }

    private var editingId: UUID? { if case .edit(let m) = route { m.id } else { nil } }
    private var lastFourIsInvalid: Bool { !lastFour.isEmpty && PaymentMethod.sanitizedLastFour(lastFour) == nil }
    private var usesCard: Bool { type == .debitCard || type == .creditCard }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(PaymentMethodType.allCases) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                    }
                    TextField("Name (e.g. Wells Fargo Debit)", text: $name)
                    if editingId == nil, !AccountPresets.suggestions(for: type).isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(AccountPresets.suggestions(for: type), id: \.self) { s in
                                    Button(s) { name = AccountPresets.defaultName(s, type: type) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                    TextField("Nickname (optional)", text: $nickname)
                }
                if usesCard || type == .bankTransfer {
                    Section {
                        TextField("Last 4 digits (optional)", text: $lastFour)
                            .keyboardType(.numberPad)
                            .onChange(of: lastFour) { _, v in if v.count > 4 { lastFour = String(v.prefix(4)) } }
                        if lastFourIsInvalid {
                            Text("Enter exactly 4 digits, or leave it empty.").font(.footnote).foregroundStyle(.red)
                        }
                    } footer: {
                        Text("Never enter a full card number, security code or bank password. TallySeam only stores the last four digits.")
                    }
                }
                if type == .applePay {
                    Section {
                        Picker("Card", selection: $underlyingId) {
                            Text("Not specified").tag(UUID?.none)
                            ForEach(methods.filter { ($0.type == .creditCard || $0.type == .debitCard) && $0.id != editingId }) { m in
                                Text(m.lastFourDigits.map { "\(m.name) •••• \($0)" } ?? m.name).tag(Optional(m.id))
                            }
                        }
                    } footer: {
                        Text("Apple Pay is how you paid, not where the money came from. Link the card behind it if you want.")
                    }
                }
                if editingId != nil {
                    Section {
                        Toggle("Active", isOn: $isActive)
                    } footer: {
                        Text("Inactive methods are hidden when adding transactions but stay on past records.")
                    }
                }
            }
            .navigationTitle(editingId == nil ? "New Payment Method" : "Edit Payment Method")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || lastFourIsInvalid)
                }
            }
            .alert("Can't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        let four = (usesCard || type == .bankTransfer) ? lastFour : ""
        do {
            switch route {
            case .new:
                let m = try app.referenceData.createPaymentMethod(name: name, type: type, nickname: nickname, lastFour: four, underlyingId: underlyingId)
                onSaved?(m.id)
            case .edit(let m):
                try app.referenceData.updatePaymentMethod(m, name: name, type: type, nickname: nickname, lastFour: four,
                                                          underlyingId: underlyingId, isActive: isActive)
                onSaved?(m.id)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
