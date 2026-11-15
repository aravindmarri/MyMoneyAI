import SwiftUI
import SwiftData

/// Phase 1: entry screen and recent receipts. Image import + on-device OCR arrive in Phase 4.
struct ReceiptScannerView: View {
    @Query(sort: \Receipt.importedAt, order: .reverse) private var receipts: [Receipt]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Scan a Receipt").font(.title2.weight(.semibold))
                        Text("Text is read on this iPhone with Apple Vision. You review every field before anything is saved.")
                            .foregroundStyle(.secondary)
                        Label("Receipt import is not available in this build yet.", systemImage: "hammer")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                Section("Recent Receipts") {
                    if receipts.isEmpty {
                        Text("No receipts imported.").foregroundStyle(.secondary)
                    } else {
                        ForEach(receipts) { r in
                            LabeledContent(r.extractedMerchant ?? "Receipt",
                                           value: r.importedAt.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
            }
            .navigationTitle("Scan")
        }
    }
}
