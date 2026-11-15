import Foundation
import Observation

/// Everything the review screen needs for one imported image.
struct ReceiptReviewState: Identifiable {
    let id = UUID()
    var receipt: ReceiptImport
    var draft: TransactionDraft
    var parsed: ParsedReceipt?
    var ocrFailed: Bool
    var suggestion: CategorySuggestion?
}

/// Builds a pre-filled, *unsaved* transaction draft from an image. Saving only happens after the
/// user reviews every field on the review screen.
@MainActor
@Observable
final class ReceiptScannerViewModel {
    var isProcessing = false
    var review: ReceiptReviewState?
    var errorMessage: String?

    func process(imageData: Data, currencyCode: String, recognizer: any ReceiptTextRecognizing,
                 suggester: any CategorySuggesting, categories: [CategoryOption], history: [TransactionRecord]) async {
        isProcessing = true
        defer { isProcessing = false }

        guard let image = ImageNormalizer.normalize(imageData) else {
            errorMessage = "This file couldn't be read as an image."
            return
        }
        let fingerprint = ImageFingerprint.fingerprint(for: image.cgImage)

        var lines: [String] = []
        do {
            lines = try await recognizer.recognizeText(in: image.cgImage)
        } catch {
            lines = []   // OCR failure is not fatal: the user can still enter everything manually.
        }

        let parsed = lines.isEmpty ? nil : ReceiptParserService().parse(lines: lines, defaultCurrency: currencyCode)
        let text = lines.joined(separator: "\n")
        var draft = Self.makeDraft(from: parsed, defaultCurrency: currencyCode)
        let suggestion = suggester.suggest(merchant: parsed?.merchant?.value, receiptText: text, kind: .expense,
                                           categories: categories, history: history)
        draft.categoryId = suggestion?.categoryId

        review = ReceiptReviewState(
            receipt: ReceiptImport(jpegData: image.jpeg, fingerprint: fingerprint, recognizedText: text.isEmpty ? nil : text, parsed: parsed),
            draft: draft, parsed: parsed, ocrFailed: lines.isEmpty, suggestion: suggestion)
    }

    /// Pure mapping from parsed values to an editable expense draft.
    nonisolated static func makeDraft(from parsed: ParsedReceipt?, defaultCurrency: String, now: Date = .now) -> TransactionDraft {
        let currency = parsed?.currencyCode?.value ?? defaultCurrency
        var draft = TransactionDraft(currencyCode: currency, date: parsed?.date?.value ?? now)
        draft.type = .expense
        draft.source = .receiptOCR
        if let total = parsed?.total {
            draft.amountText = TransactionDraft.editableAmount(total.value, currencyCode: currency)
        }
        if let merchant = parsed?.merchant?.value {
            draft.merchant = merchant
            draft.title = merchant
        }
        return draft
    }
}
