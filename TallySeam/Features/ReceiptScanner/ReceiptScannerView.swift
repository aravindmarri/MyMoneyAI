import SwiftUI
import SwiftData
import PhotosUI

struct ReceiptScannerView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Receipt.importedAt, order: .reverse) private var receipts: [Receipt]
    @Query private var transactions: [MoneyTransaction]
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query private var settings: [AppSettings]

    @State private var model = ReceiptScannerViewModel()
    @State private var importCenter = ImportCenterModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }
    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        NavigationStack {
            List {
                ImportCenterSection(model: importCenter, currency: currency) { data in Task { await process(data) } }
                SavedStatementsSection()
                importSection
                recentSection
            }
            .navigationTitle("Import")
            .navigationDestination(for: UUID.self) { TransactionDetailView(transactionID: $0) }
            .overlay { if model.isProcessing { processingOverlay } }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in Task { await process(data) } }
                    .ignoresSafeArea()
            }
            .sheet(item: $model.review) { state in
                ReceiptReviewView(state: state)
            }
            .alert("Couldn't Import", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var importSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Scan a Receipt").font(.title3.weight(.semibold))
                Text("Text is read on this iPhone with Apple Vision. Nothing is uploaded, and you review every field before it's saved.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose Photo or Screenshot", systemImage: "photo.on.rectangle")
            }
            if cameraAvailable {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
            }
        }
        .disabled(model.isProcessing)
    }

    private var recentSection: some View {
        Section("Recent Receipts") {
            if receipts.isEmpty {
                Text("No receipts imported.").foregroundStyle(.secondary)
            } else {
                ForEach(receipts.prefix(20)) { receipt in
                    recentRow(receipt)
                }
            }
        }
    }

    @ViewBuilder
    private func recentRow(_ receipt: Receipt) -> some View {
        let linked = transactions.first { $0.receiptId == receipt.id }
        let row = HStack(spacing: 12) {
            ReceiptThumbnail(relativePath: receipt.imageRelativePath, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(linked?.merchant ?? linked?.title ?? receipt.extractedMerchant ?? "Receipt").lineLimit(1)
                Text(receipt.importedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let linked {
                Text(CurrencyMath.format(linked.amountMinorUnits, currencyCode: linked.currencyCode))
                    .monospacedDigit()
            }
        }
        if let linked {
            NavigationLink(value: linked.id) { row }
        } else {
            row
        }
    }

    private var processingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading receipt…").font(.subheadline)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private func load(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                model.errorMessage = "The selected item couldn't be loaded."
                return
            }
            await process(data)
        } catch {
            model.errorMessage = "The selected item couldn't be loaded."
        }
    }

    private func process(_ data: Data) async {
        let options = categories.map { CategoryOption(id: $0.id, name: $0.name, kind: $0.kind) }
        await model.process(imageData: data, currencyCode: currency, recognizer: app.textRecognizer,
                            suggester: app.categorySuggester, categories: options, history: transactions.map(\.record))
    }
}

/// Loads a stored receipt image from disk and shows it as a small thumbnail.
struct ReceiptThumbnail: View {
    @Environment(AppContainer.self) private var app
    let relativePath: String
    var size: CGFloat = 44
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: relativePath) {
            image = app.receipts.storage.loadData(relativePath: relativePath).flatMap(UIImage.init(data:))
        }
    }
}

/// Wraps UIImagePickerController for taking a receipt photo with the camera.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onImage(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
