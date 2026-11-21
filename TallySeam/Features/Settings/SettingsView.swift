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
                    NavigationLink { BillsView() } label: { Label("Recurring Bills", systemImage: "calendar.badge.clock") }
                    NavigationLink { BudgetsView() } label: { Label("Budgets", systemImage: "gauge.with.dots.needle.33percent") }
                }
                if let s = settings.first {
                    PreferencesSection(settings: s)
                }
                if let s = settings.first {
                    SecuritySection(settings: s)
                }
                SmartSuggestionsSection()
                Section("Data") {
                    NavigationLink { DataManagementView() } label: { Label("Backup & Data", systemImage: "externaldrive") }
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

/// Optional Apple Intelligence for statement suggestions. Off by default; the built-in rules always work.
private struct SmartSuggestionsSection: View {
    @AppStorage(DescriptionAssistantFactory.preferenceKey) private var useOnDeviceModel = false

    var body: some View {
        Section {
            Toggle(isOn: $useOnDeviceModel) { Label("Use Apple Intelligence", systemImage: "sparkles") }
                .disabled(!DescriptionAssistantFactory.isOnDeviceModelAvailable)
        } header: {
            Text("Smart Suggestions")
        } footer: {
            Text(DescriptionAssistantFactory.isOnDeviceModelAvailable
                 ? "Helps explain unusual statement descriptions and suggest merchant names, on this iPhone only. It never changes amounts or saves anything by itself."
                 : DescriptionAssistantFactory.onDeviceModelStatus + " The built-in rules work fully offline.")
        }
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
                Text("TallySeam stores your records in an encrypted-at-rest database protected by iOS Data Protection. It never connects to your bank and never stores full card numbers.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy")
    }
}
