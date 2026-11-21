import SwiftUI
import SwiftData
import Observation

/// Files imported in this session and their reading state. Files are read from the picker's
/// security-scoped URLs into memory; nothing is copied to storage or saved to the database here.
@MainActor
@Observable
final class ImportCenterModel {
    var documents: [ImportedDocument] = []
    var readingMessage: String?
    var errorMessage: String?

    var isReading: Bool { readingMessage != nil }

    func importFiles(_ urls: [URL], service: StatementImportService, currency: String) async {
        for (i, url) in urls.enumerated() {
            let name = url.lastPathComponent
            readingMessage = urls.count > 1 ? "Reading \(i + 1) of \(urls.count): \(name)" : "Reading \(name)…"
            guard let data = Self.readFile(url) else {
                documents.insert(ImportedDocument(filename: name, format: .unknown, byteCount: 0, fingerprint: "",
                                                  content: .failed("The file couldn't be read, or it's larger than \(DocumentLimits.maximumFileBytes / 1_048_576) MB.")), at: 0)
                continue
            }
            let doc = await service.read(filename: name, data: data, defaultCurrency: currency) { page, total in
                Task { @MainActor [weak self] in
                    self?.readingMessage = "Reading \(name): page \(page) of \(total)"
                }
            }
            documents.insert(doc, at: 0)
        }
        readingMessage = nil
    }

    /// Tries a password on a protected PDF. The password is used for this read only.
    func unlock(_ id: UUID, password: String, service: StatementImportService, currency: String) async -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == id }), case .needsPassword(let data) = documents[index].content else { return false }
        readingMessage = "Opening \(documents[index].filename)…"
        defer { readingMessage = nil }
        let doc = await service.read(filename: documents[index].filename, data: data, password: password, defaultCurrency: currency)
        if case .failed(let message) = doc.content, message == DocumentReadError.wrongPassword.localizedDescription {
            errorMessage = message
            return false
        }
        documents[index] = doc
        return true
    }

    func remove(_ id: UUID) { documents.removeAll { $0.id == id } }

    private static func readFile(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= DocumentLimits.maximumFileBytes else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}

/// Statement, CSV and file import section of the Import tab.
struct ImportCenterSection: View {
    @Environment(AppContainer.self) private var app
    @Bindable var model: ImportCenterModel
    let currency: String
    /// Hands a photo or screenshot to the receipt scanner.
    let onImage: (Data) -> Void

    @State private var showPicker = false
    @State private var csvRequest: CSVImportRequest?
    @State private var passwordFor: ImportedDocument?
    @State private var resultMessage: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "doc.on.doc").font(.system(size: 40)).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Import Statements & Files").font(.title3.weight(.semibold))
                Text("Bank and credit card statements (PDF, CSV, TXT), receipts and screenshots. Everything is read on this iPhone; nothing is uploaded.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            Button { showPicker = true } label: { Label("Choose Files", systemImage: "folder") }
                .disabled(model.isReading)
            if let message = model.readingMessage {
                HStack(spacing: 10) { ProgressView(); Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: DocumentFormat.importableTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await model.importFiles(urls, service: StatementImportService(recognizer: app.textRecognizer), currency: currency) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        if !model.documents.isEmpty {
            Section {
                ForEach($model.documents) { $doc in
                    row($doc)
                        .swipeActions { Button("Remove", role: .destructive) { model.remove(doc.id) } }
                }
            } header: {
                Text("Imported Files")
            } footer: {
                Text("Open a statement to check what was read, then save it to find matching transactions. Swipe to remove a file from this list.")
            }
            .sheet(item: $csvRequest) { request in
                CSVImportView(table: request.table) { message in resultMessage = message }
            }
            .sheet(item: $passwordFor) { doc in
                PDFPasswordView(filename: doc.filename) { password in
                    Task {
                        _ = await model.unlock(doc.id, password: password,
                                               service: StatementImportService(recognizer: app.textRecognizer), currency: currency)
                    }
                }
            }
            .alert("Import", isPresented: Binding(get: { resultMessage != nil || model.errorMessage != nil },
                                                  set: { if !$0 { resultMessage = nil; model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(resultMessage ?? model.errorMessage ?? "") }
        }
    }

    @ViewBuilder
    private func row(_ doc: Binding<ImportedDocument>) -> some View {
        let d = doc.wrappedValue
        switch d.content {
        case .statement:
            NavigationLink {
                StatementPreviewView(document: doc)
            } label: {
                fileLabel(d, detail: statementDetail(d), symbol: "doc.text.magnifyingglass", tint: .accentColor)
            }
        case .csv(let table):
            Button { csvRequest = CSVImportRequest(table: table) } label: {
                fileLabel(d, detail: "Transaction export · \(max(0, table.rows.count - 1)) rows · Tap to map columns", symbol: "tablecells", tint: .accentColor)
            }
        case .image(let data):
            Button { onImage(data) } label: {
                fileLabel(d, detail: "Image · Tap to read as a receipt", symbol: "photo", tint: .accentColor)
            }
        case .needsPassword:
            Button { passwordFor = d } label: {
                fileLabel(d, detail: "Password protected · Tap to enter the password", symbol: "lock.doc", tint: .orange)
            }
        case .failed(let reason):
            fileLabel(d, detail: reason, symbol: "exclamationmark.triangle", tint: .orange)
        }
    }

    private func statementDetail(_ d: ImportedDocument) -> String {
        guard case .statement(let p) = d.content else { return "" }
        var parts = [p.kind.displayName, "\(p.parse.lines.count) transactions"]
        if !p.parse.issues.isEmpty { parts.append("\(p.parse.issues.count) to check") }
        return parts.joined(separator: " · ")
    }

    private func fileLabel(_ d: ImportedDocument, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.filename).lineLimit(1).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Asks for a PDF's password. It's passed straight to PDFKit and never stored or logged.
struct PDFPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    let filename: String
    let onSubmit: (String) -> Void
    @State private var password = ""

    init(filename: String, onSubmit: @escaping (String) -> Void) {
        self.filename = filename
        self.onSubmit = onSubmit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PDF password", text: $password).textContentType(.password)
                } footer: {
                    Text("“\(filename)” is protected. The password is used only to open it now and is never saved.")
                }
            }
            .brandScreen()
            .navigationTitle("Open PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        let p = password
                        password = ""
                        dismiss()
                        onSubmit(p)
                    }
                    .disabled(password.isEmpty)
                }
            }
        }
    }
}
