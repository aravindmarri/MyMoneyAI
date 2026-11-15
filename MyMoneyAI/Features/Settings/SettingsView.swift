import SwiftUI
import SwiftData

struct SettingsView: View {
    @Query private var settings: [AppSettings]

    var body: some View {
        NavigationStack {
            List {
                Section("Organize") {
                    NavigationLink { CategoriesView() } label: { Label("Categories", systemImage: "square.grid.2x2") }
                    NavigationLink { PaymentMethodsView() } label: { Label("Payment Methods", systemImage: "creditcard") }
                    NavigationLink { BillsListView() } label: { Label("Recurring Bills", systemImage: "calendar.badge.clock") }
                    NavigationLink { BudgetsListView() } label: { Label("Budgets", systemImage: "gauge.with.dots.needle.33percent") }
                }
                if let s = settings.first {
                    PreferencesSection(settings: s)
                }
                Section("About") {
                    NavigationLink { PrivacyInfoView() } label: { Label("Privacy", systemImage: "lock.shield") }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct PreferencesSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("Preferences") {
            Picker("Currency", selection: $settings.preferredCurrencyCode) {
                ForEach(CurrencyMath.supportedCodes, id: \.self) { Text($0).tag($0) }
            }
            Picker("Appearance", selection: Binding(get: { settings.preferredAppearance },
                                                    set: { settings.preferredAppearance = $0 })) {
                ForEach(AppearancePreference.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }
}

struct BillsListView: View {
    @Query(sort: \RecurringBill.nextDueDate) private var bills: [RecurringBill]

    var body: some View {
        Group {
            if bills.isEmpty {
                EmptyStateView(title: "No Recurring Bills", systemImage: "calendar.badge.clock",
                               message: "Bills are reminders of what you owe. They are not counted as spending until you record a payment.")
            } else {
                List(bills) { b in
                    LabeledContent(b.title, value: b.nextDueDate.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
        .navigationTitle("Recurring Bills")
    }
}

struct BudgetsListView: View {
    @Query private var budgets: [Budget]

    var body: some View {
        Group {
            if budgets.isEmpty {
                EmptyStateView(title: "No Budgets", systemImage: "gauge.with.dots.needle.33percent",
                               message: "Set a monthly limit overall or per category to track progress.")
            } else {
                List(budgets) { b in
                    Text(CurrencyMath.format(b.amountMinorUnits, currencyCode: b.currencyCode))
                }
            }
        }
        .navigationTitle("Budgets")
    }
}

struct PrivacyInfoView: View {
    var body: some View {
        List {
            Section {
                Label("Works fully offline", systemImage: "airplane")
                Label("No account, ads or analytics", systemImage: "person.crop.circle.badge.xmark")
                Label("Data never leaves this iPhone", systemImage: "iphone")
                Label("No iCloud sync", systemImage: "icloud.slash")
                Label("Receipts read on-device with Apple Vision", systemImage: "text.viewfinder")
            }
            Section {
                Text("MyMoney AI stores your records in an encrypted-at-rest database protected by iOS Data Protection. It never connects to your bank and never stores full card numbers.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy")
    }
}
