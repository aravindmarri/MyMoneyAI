import SwiftUI
import SwiftData

/// Add cash, debit cards and credit cards in one go, e.g. Cash, Wells Fargo Debit, Capital One
/// Credit and American Express Credit. Only names and optional last four digits are stored.
struct AccountSetupView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PaymentMethod.createdAt) private var existing: [PaymentMethod]

    @State private var includeCash = false
    @State private var items: [AccountSetupItem] = []
    @State private var errorMessage: String?
    var onFinished: ((Int) -> Void)? = nil

    init(onFinished: ((Int) -> Void)? = nil) { self.onFinished = onFinished }

    private var existingNames: Set<String> { Set(existing.map { $0.name.lowercased() }) }
    private var hasCash: Bool { existing.contains { $0.type == .cash } }

    private var allItems: [AccountSetupItem] {
        (includeCash && !hasCash ? [AccountSetupItem(name: "Cash", type: .cash)] : []) + items
    }
    private var addCount: Int {
        (try? AccountSetup.itemsToCreate(allItems, existingNames: existing.map(\.name)).count) ?? allItems.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasCash {
                        Label("Cash is already added", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    } else {
                        Toggle(isOn: $includeCash) { Label("Cash", systemImage: PaymentMethodType.cash.symbol) }
                    }
                } footer: {
                    Text("Add every way you pay, so spending can be split by card, cash and account.")
                }
                accountSection(title: "Debit cards & bank accounts", type: .debitCard,
                               presets: AccountPresets.debitBanks, addLabel: "Add a Debit Card")
                accountSection(title: "Credit cards", type: .creditCard,
                               presets: AccountPresets.creditIssuers, addLabel: "Add a Credit Card")
                Section {
                    Label("Never enter a full card number, security code or online banking password. Only the last 4 digits are kept, and only if you add them.",
                          systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .brandScreen()
            .navigationTitle("Set Up Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(addCount > 0 ? "Add \(addCount)" : "Add", action: save).disabled(addCount == 0)
                }
            }
            .alert("Can't Add", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    @ViewBuilder
    private func accountSection(title: String, type: PaymentMethodType, presets: [String], addLabel: String) -> some View {
        Section(title) {
            ForEach(existing.filter { $0.type == type && $0.isActive }) { m in
                Label(m.lastFourDigits.map { "\(m.name) •••• \($0)" } ?? m.name, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            ForEach($items) { $item in
                if item.type == type {
                    HStack {
                        TextField("Name", text: $item.name)
                        TextField("Last 4", text: $item.lastFour)
                            .keyboardType(.numberPad)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: item.lastFour) { _, v in if v.count > 4 { item.lastFour = String(v.prefix(4)) } }
                        Button { remove(item.id) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(item.name)")
                    }
                }
            }
            Menu {
                ForEach(presets, id: \.self) { bank in
                    let name = AccountPresets.defaultName(bank, type: type)
                    Button(bank) { add(name: name, type: type) }
                        .disabled(isTaken(name))
                }
                Divider()
                Button("Other…") { add(name: "", type: type) }
            } label: {
                Label(addLabel, systemImage: "plus.circle.fill")
            }
        }
    }

    private func isTaken(_ name: String) -> Bool {
        existingNames.contains(name.lowercased()) || items.contains { $0.name.lowercased() == name.lowercased() }
    }

    private func add(name: String, type: PaymentMethodType) {
        withAnimation { items.append(AccountSetupItem(name: name, type: type)) }
    }

    private func remove(_ id: UUID) {
        withAnimation { items.removeAll { $0.id == id } }
    }

    private func save() {
        do {
            let n = try app.referenceData.createPaymentMethods(allItems, existingNames: existing.map(\.name))
            dismiss()
            onFinished?(n)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
