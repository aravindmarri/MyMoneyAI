import SwiftUI
import SwiftData

/// Side-by-side review of the receipt image and the extracted fields. Every value is editable,
/// uncertain values are flagged, and nothing is stored until the user taps Save.
struct ReceiptReviewView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query(sort: \PaymentMethod.createdAt) private var methods: [PaymentMethod]
    @Query private var transactions: [MoneyTransaction]
    @Query private var receipts: [Receipt]

    let state: ReceiptReviewState
    @State private var draft: TransactionDraft
    @State private var image: UIImage?
    @State private var showFullImage = false
    @State private var confirmDuplicate = false
    @State private var errorMessage: String?

    init(state: ReceiptReviewState) {
        self.state = state
        _draft = State(initialValue: state.draft)
        _image = State(initialValue: UIImage(data: state.receipt.jpegData))
    }

    private var parsed: ParsedReceipt? { state.parsed }
    private var categoryKinds: [UUID: CategoryKind] { Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.kind) }) }

    private var duplicates: [DuplicateMatch] {
        DuplicateDetectionService.findDuplicates(
            fingerprint: state.receipt.fingerprint, amountMinorUnits: draft.amountMinorUnits, date: draft.date,
            merchant: draft.merchant,
            receipts: receipts.map { ReceiptFingerprintEntry(id: $0.id, fingerprint: $0.imageFingerprint) },
            transactions: transactions.map(\.record), calendar: .current)
    }

    var body: some View {
        NavigationStack {
            Form {
                imageSection
                statusSection
                if !duplicates.isEmpty { duplicatesSection }
                amountSection
                detailsSection
                categorySection
                paymentSection
                recognizedTextSection
            }
            .navigationTitle("Review Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .fullScreenCover(isPresented: $showFullImage) { fullImage }
            .confirmationDialog("Possible Duplicate", isPresented: $confirmDuplicate, titleVisibility: .visible) {
                Button("Save Anyway") { save() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(duplicates.first?.message ?? "")
            }
            .alert("Can't Save", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: Sections

    private var imageSection: some View {
        Section {
            Button { showFullImage = true } label: {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo").font(.largeTitle)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 260)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Receipt image. Double-tap to enlarge.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if state.ocrFailed {
            Section {
                Label("No text could be read. Enter the details manually.", systemImage: "text.badge.xmark")
                    .foregroundStyle(.orange)
            }
        } else {
            Section {
                Label("Check the highlighted fields before saving.", systemImage: "checkmark.shield")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var duplicatesSection: some View {
        Section("Possible Duplicate") {
            ForEach(duplicates) { match in
                VStack(alignment: .leading, spacing: 8) {
                    Label(match.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if let id = match.transactionId, canLink(to: id) {
                        Button("Attach Receipt to That Expense Instead") { link(to: id) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var amountSection: some View {
        Section("Amount") {
            HStack {
                TextField("0.00", text: $draft.amountText)
                    .keyboardType(.decimalPad)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .accessibilityLabel("Total amount")
                ConfidenceBadge(confidence: parsed?.total?.confidence)
            }
            Picker("Currency", selection: $draft.currencyCode) {
                ForEach(CurrencyMath.supportedCodes, id: \.self) { code in
                    Text(code).tag(code)
                }
            }
            if let tax = parsed?.taxMinorUnits {
                LabeledContent("Tax on receipt", value: CurrencyMath.format(tax, currencyCode: draft.currencyCode))
            }
            if let discount = parsed?.discountMinorUnits {
                LabeledContent("Discounts on receipt", value: CurrencyMath.format(discount, currencyCode: draft.currencyCode))
            }
            Toggle("This is a refund", isOn: $draft.isRefund)
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            HStack {
                TextField("Merchant", text: $draft.merchant)
                ConfidenceBadge(confidence: parsed?.merchant?.confidence)
            }
            TextField("Title (optional)", text: $draft.title)
            HStack {
                DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                ConfidenceBadge(confidence: parsed?.date?.confidence)
            }
        }
    }

    private var categorySection: some View {
        Section {
            Picker("Category", selection: $draft.categoryId) {
                Text("Uncategorized").tag(UUID?.none)
                ForEach(categories.filter { $0.kind == .expense }) { (c: SpendingCategory) in
                    Label(c.name, systemImage: c.symbol).tag(UUID?.some(c.id))
                }
            }
        } header: {
            Text("Category")
        } footer: {
            if let s = state.suggestion, draft.categoryId == s.categoryId {
                Text("Suggested. \(s.source.explanation).")
            }
        }
    }

    private var paymentSection: some View {
        Section("Paid With") {
            Picker("Payment method", selection: $draft.paymentMethodId) {
                Text("Not specified").tag(UUID?.none)
                ForEach(methods.filter(\.isActive)) { (m: PaymentMethod) in
                    Text(m.lastFourDigits.map { "\(m.name) •••• \($0)" } ?? m.name).tag(UUID?.some(m.id))
                }
            }
            if methods.isEmpty {
                Text("Add payment methods in Settings to track how you paid.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var recognizedTextSection: some View {
        if let text = state.receipt.recognizedText {
            Section {
                DisclosureGroup("Recognized Text") {
                    Text(text)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var fullImage: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(minWidth: 300)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showFullImage = false } }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Discard") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                if duplicates.isEmpty { save() } else { confirmDuplicate = true }
            }
            .disabled(draft.amountText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    // MARK: Actions

    private func canLink(to transactionId: UUID) -> Bool {
        transactions.first { $0.id == transactionId }?.receiptId == nil
    }

    private func save() {
        do {
            try app.receipts.saveNewTransaction(from: draft, receipt: state.receipt, categoryKinds: categoryKinds)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func link(to transactionId: UUID) {
        do {
            try app.receipts.link(receipt: state.receipt, toTransaction: transactionId)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Small pill showing how sure the parser was; nil means the field wasn't found.
struct ConfidenceBadge: View {
    let confidence: ParseConfidence?

    var body: some View {
        let label = confidence?.label ?? "Not found"
        let color: Color = switch confidence {
        case .high: .green
        case .medium: .blue
        case .low, .none: .orange
        }
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Recognition: \(label)")
    }
}
