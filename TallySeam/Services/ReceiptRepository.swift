import Foundation
import SwiftData

/// A reviewed receipt ready to store: normalized image plus what OCR extracted.
struct ReceiptImport: Sendable {
    var jpegData: Data
    var fingerprint: String?
    var recognizedText: String?
    var parsed: ParsedReceipt?
}

/// Saves receipts and links them to transactions. The image file and the database rows are
/// written together; if the database save fails, the file is removed again.
@MainActor
final class ReceiptRepository {
    private let context: ModelContext
    let storage: ReceiptStorageService

    init(context: ModelContext, storage: ReceiptStorageService) {
        self.context = context
        self.storage = storage
    }

    func fingerprints() throws -> [ReceiptFingerprintEntry] {
        try context.fetch(FetchDescriptor<Receipt>()).map { ReceiptFingerprintEntry(id: $0.id, fingerprint: $0.imageFingerprint) }
    }

    func fetch(id: UUID) throws -> Receipt? {
        var d = FetchDescriptor<Receipt>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    func imageData(forReceipt id: UUID) -> Data? {
        guard let receipt = try? fetch(id: id) else { return nil }
        return storage.loadData(relativePath: receipt.imageRelativePath)
    }

    /// Creates a new verified transaction with the receipt attached. The draft is validated
    /// before anything is written to disk.
    @discardableResult
    func saveNewTransaction(from draft: TransactionDraft, receipt: ReceiptImport,
                            categoryKinds: [UUID: CategoryKind], now: Date = .now) throws -> TransactionRecord {
        let receiptId = UUID()
        var d = draft
        d.editingId = nil
        d.receiptId = receiptId
        d.source = .receiptOCR
        let record = try d.makeRecord(categoryKinds: categoryKinds, now: now)

        let path = try storage.save(jpegData: receipt.jpegData, id: receiptId)
        context.insert(makeReceipt(id: receiptId, path: path, receipt: receipt, now: now))
        context.insert(MoneyTransaction(record: record))
        try saveOrRollBack(removing: path)
        return record
    }

    /// Attaches the receipt to an existing transaction instead of creating a new one
    /// (used when the receipt belongs to an expense the user already entered).
    func link(receipt: ReceiptImport, toTransaction transactionId: UUID, now: Date = .now) throws {
        var d = FetchDescriptor<MoneyTransaction>(predicate: #Predicate { $0.id == transactionId })
        d.fetchLimit = 1
        guard let transaction = try context.fetch(d).first else { throw RepositoryError.notFound }
        guard transaction.receiptId == nil else { throw RepositoryError.receiptAlreadyAttached }

        let receiptId = UUID()
        let path = try storage.save(jpegData: receipt.jpegData, id: receiptId)
        context.insert(makeReceipt(id: receiptId, path: path, receipt: receipt, now: now))
        transaction.receiptId = receiptId
        transaction.updatedAt = now
        try saveOrRollBack(removing: path)
    }

    /// Deletes image files that no receipt references (left by an interrupted save).
    @discardableResult
    func removeOrphanedImages() throws -> Int {
        let referenced = Set(try context.fetch(FetchDescriptor<Receipt>()).map(\.imageRelativePath))
        return try storage.removeOrphans(referenced: referenced)
    }

    private func makeReceipt(id: UUID, path: String, receipt: ReceiptImport, now: Date) -> Receipt {
        let r = Receipt(id: id, imageRelativePath: path, importedAt: now, imageFingerprint: receipt.fingerprint)
        r.extractedText = receipt.recognizedText
        r.extractedMerchant = receipt.parsed?.merchant?.value
        r.extractedDate = receipt.parsed?.date?.value
        r.extractedTotalMinorUnits = receipt.parsed?.total?.value
        r.currencyCode = receipt.parsed?.currencyCode?.value
        r.reviewStatus = .reviewed
        return r
    }

    private func saveOrRollBack(removing path: String) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            try? storage.delete(relativePath: path)
            throw error
        }
    }
}
