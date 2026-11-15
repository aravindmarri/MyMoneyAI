import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// App lock toggle. Turning it on or off requires the owner to authenticate.
struct SecuritySection: View {
    @Environment(AppContainer.self) private var app
    @Bindable var settings: AppSettings
    @State private var message: String?

    init(settings: AppSettings) { self.settings = settings }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.requireBiometricUnlock }, set: { change(to: $0) })) {
                Label("Require \(app.lock.biometryName)", systemImage: "lock")
            }
            .disabled(!app.lock.isAvailable)
        } header: {
            Text("Security")
        } footer: {
            Text(app.lock.isAvailable
                 ? "Locks the app when you leave it. The app is always hidden in the app switcher."
                 : "Set up a passcode in the iPhone Settings app to use the app lock.")
        }
        .alert("App Lock", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func change(to enabled: Bool) {
        Task {
            if await app.lock.confirmChange() {
                settings.requireBiometricUnlock = enabled
            } else {
                message = "The setting wasn't changed because authentication didn't succeed."
            }
        }
    }
}

/// An encrypted backup file handed to the system file exporter.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw BackupError.notABackup }
        data = d
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct DataManagementView: View {
    private enum PasswordPurpose: Identifiable {
        case export, importFile(Data)
        var id: String { if case .export = self { "export" } else { "import" } }
    }

    @Environment(AppContainer.self) private var app
    @Query private var receipts: [Receipt]
    @Query private var transactions: [MoneyTransaction]
    @State private var passwordPurpose: PasswordPurpose?
    @State private var exportDocument: BackupDocument?
    @State private var showImporter = false
    @State private var working = false
    @State private var resultMessage: String?
    @State private var confirmReceiptCleanup = false
    @State private var showDeleteAll = false

    private var unattachedCount: Int {
        let used = Set(transactions.compactMap(\.receiptId))
        return receipts.filter { !used.contains($0.id) }.count
    }

    var body: some View {
        List {
            backupSection
            Section {
                LabeledContent("Unattached receipts", value: "\(unattachedCount)")
                Button("Delete Unattached Receipts", role: .destructive) { confirmReceiptCleanup = true }
                    .disabled(unattachedCount == 0)
            } header: {
                Text("Receipts")
            } footer: {
                Text("Receipts whose transaction was deleted. Their images still take up space on this iPhone.")
            }
            Section {
                Button("Delete All Data", role: .destructive) { showDeleteAll = true }
            } footer: {
                Text("Permanently erases every transaction, receipt, bill, budget, payment method and custom category on this iPhone.")
            }
        }
        .navigationTitle("Backup & Data")
        .disabled(working)
        .overlay { if working { ProgressView("Working…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
        .sheet(item: $passwordPurpose) { purpose in
            switch purpose {
            case .export: BackupPasswordView(isExport: true) { password in export(password: password) }
            case .importFile(let data): BackupPasswordView(isExport: false) { password in importBackup(data, password: password) }
            }
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json, defaultFilename: Self.defaultFilename()) { result in
            if case .failure(let error) = result { resultMessage = error.localizedDescription }
            else { resultMessage = "Backup saved. Keep the password safe: without it the backup can't be opened." }
            exportDocument = nil
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .data]) { result in readImport(result) }
        .confirmationDialog("Delete \(unattachedCount) unattached receipts?", isPresented: $confirmReceiptCleanup, titleVisibility: .visible) {
            Button("Delete Receipts", role: .destructive) { run {
                let n = try app.backup.deleteUnattachedReceipts()
                return "Deleted \(n) receipts."
            } }
        } message: { Text("This can't be undone. Transactions are not affected.") }
        .sheet(isPresented: $showDeleteAll) {
            DeleteAllDataView { run { try app.backup.deleteAllData(); return "All data was deleted." } }
        }
        .alert("Backup & Data", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(resultMessage ?? "") }
    }

    private var backupSection: some View {
        Section {
            Button { passwordPurpose = .export } label: { Label("Export Encrypted Backup", systemImage: "square.and.arrow.up") }
            Button { showImporter = true } label: { Label("Import Backup", systemImage: "square.and.arrow.down") }
        } header: {
            Text("Backup")
        } footer: {
            Text("Backups are encrypted with your password (AES-256-GCM) and include receipt images. You choose where the file is saved. Importing only adds items that aren't already on this iPhone.")
        }
    }

    static func defaultFilename(now: Date = .now) -> String {
        "MyMoneyAI-Backup-\(now.formatted(.iso8601.year().month().day()))"
    }

    private func run(_ action: () throws -> String) {
        do { resultMessage = try action() } catch { resultMessage = error.localizedDescription }
    }

    private func export(password: String) {
        working = true
        do {
            let plaintext = try BackupService.encode(try app.backup.makePayload())
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try BackupCrypto.encrypt(plaintext, password: password) }
                }.value
                working = false
                switch result {
                case .success(let data): exportDocument = BackupDocument(data: data)
                case .failure(let error): resultMessage = error.localizedDescription
                }
            }
        } catch {
            working = false
            resultMessage = error.localizedDescription
        }
    }

    private func readImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            resultMessage = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= BackupCrypto.maximumFileBytes else { throw BackupError.tooLarge }
                passwordPurpose = .importFile(try Data(contentsOf: url))
            } catch {
                resultMessage = error.localizedDescription
            }
        }
    }

    private func importBackup(_ file: Data, password: String) {
        working = true
        Task {
            let decrypted = await Task.detached(priority: .userInitiated) {
                Result { try BackupService.decode(try BackupCrypto.decrypt(file, password: password)) }
            }.value
            defer { working = false }
            do {
                let s = try app.backup.restore(try decrypted.get())
                var lines = ["Added \(s.transactionsAdded) transactions, \(s.receiptsAdded) receipts, \(s.billsAdded) bills, \(s.budgetsAdded) budgets, \(s.paymentMethodsAdded) payment methods and \(s.categoriesAdded) categories."]
                if s.transactionsSkipped > 0 { lines.append("\(s.transactionsSkipped) transactions were already on this iPhone and were skipped.") }
                if s.budgetsPaused > 0 { lines.append("\(s.budgetsPaused) budgets were added as paused because a matching budget already exists.") }
                resultMessage = lines.joined(separator: "\n\n")
            } catch {
                resultMessage = error.localizedDescription
            }
        }
    }
}

struct BackupPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    let isExport: Bool
    let onSubmit: (String) -> Void
    @State private var password = ""
    @State private var confirmation = ""

    init(isExport: Bool, onSubmit: @escaping (String) -> Void) {
        self.isExport = isExport
        self.onSubmit = onSubmit
    }

    private var valid: Bool {
        isExport ? BackupCrypto.isAcceptable(password: password) && password == confirmation : !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password).textContentType(isExport ? .newPassword : .password)
                    if isExport { SecureField("Confirm password", text: $confirmation).textContentType(.newPassword) }
                } footer: {
                    Text(isExport
                         ? "At least \(BackupCrypto.minimumPasswordLength) characters. The password can't be recovered: if you forget it, the backup can't be opened."
                         : "Enter the password used when the backup was made.")
                }
                if isExport, !confirmation.isEmpty, password != confirmation {
                    Text("The passwords don't match.").foregroundStyle(.orange)
                }
            }
            .navigationTitle(isExport ? "Encrypt Backup" : "Open Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isExport ? "Export" : "Import") {
                        let p = password
                        dismiss()
                        onSubmit(p)
                    }
                    .disabled(!valid)
                }
            }
        }
    }
}

/// Requires typing DELETE before erasing everything.
struct DeleteAllDataView: View {
    @Environment(\.dismiss) private var dismiss
    let onConfirm: () -> Void
    @State private var typed = ""

    init(onConfirm: @escaping () -> Void) { self.onConfirm = onConfirm }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This permanently erases all your transactions, receipts and their images, bills, budgets, payment methods and custom categories, and resets settings. It can't be undone.")
                    Text("Export a backup first if you might need this data again.").foregroundStyle(.secondary)
                }
                Section("Type DELETE to confirm") {
                    TextField("DELETE", text: $typed)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("Delete All Data", role: .destructive) {
                        dismiss()
                        onConfirm()
                    }
                    .disabled(typed != "DELETE")
                }
            }
            .navigationTitle("Delete All Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
