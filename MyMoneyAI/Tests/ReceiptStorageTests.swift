import Foundation
import SwiftData
import XCTest
@testable import MyMoneyAI

/// File storage and SwiftData linking for receipts. Uses a temporary directory and an in-memory store.
@MainActor
final class ReceiptStorageTests: XCTestCase {
    private var root: URL!
    private var storage: ReceiptStorageService!
    private var persistence: PersistenceService!
    private var receipts: ReceiptRepository!
    private var transactions: TransactionRepository!
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0xFF, 0xD9])   // synthetic bytes

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ReceiptTests-\(UUID().uuidString)")
        storage = ReceiptStorageService(rootURL: root)
        persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        receipts = ReceiptRepository(context: persistence.context, storage: storage)
        transactions = TransactionRepository(context: persistence.context)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func draft(_ amount: String = "8.39") -> TransactionDraft {
        var d = TransactionDraft(currencyCode: "USD")
        d.merchant = "Corner Cafe"
        d.amountText = amount
        return d
    }

    private func receiptImport() -> ReceiptImport {
        var parsed = ParsedReceipt()
        parsed.total = ParsedValue(value: 839, confidence: .high)
        parsed.merchant = ParsedValue(value: "Corner Cafe", confidence: .medium)
        return ReceiptImport(jpegData: jpeg, fingerprint: ImageFingerprint.string(42), recognizedText: "CORNER CAFE\nTOTAL 8.39", parsed: parsed)
    }

    // MARK: Storage

    func testSaveLoadDelete() throws {
        let id = UUID()
        let path = try storage.save(jpegData: jpeg, id: id)
        XCTAssertEqual(path, "Receipts/\(id.uuidString).jpg")
        XCTAssertEqual(storage.loadData(relativePath: path), jpeg)
        try storage.delete(relativePath: path)
        XCTAssertNil(storage.loadData(relativePath: path))
    }

    func testRejectsPathTraversal() {
        XCTAssertThrowsError(try storage.url(forRelativePath: "../Store/MyMoney.store"))
        XCTAssertThrowsError(try storage.url(forRelativePath: "Receipts/../../secret.jpg"))
        XCTAssertNil(storage.loadData(relativePath: "/etc/passwd"))
    }

    func testOrphanCleanupKeepsReferencedFiles() throws {
        let kept = try storage.save(jpegData: jpeg, id: UUID())
        let orphan = try storage.save(jpegData: jpeg, id: UUID())
        XCTAssertEqual(try storage.orphanedPaths(referenced: [kept]), [orphan])
        XCTAssertEqual(try storage.removeOrphans(referenced: [kept]), 1)
        XCTAssertTrue(storage.fileExists(relativePath: kept))
        XCTAssertFalse(storage.fileExists(relativePath: orphan))
    }

    // MARK: Repository

    func testSaveCreatesLinkedVerifiedTransactionAndReceipt() throws {
        let kinds = try ReferenceDataRepository(context: persistence.context).categoryKinds()
        let record = try receipts.saveNewTransaction(from: draft(), receipt: receiptImport(), categoryKinds: kinds)

        XCTAssertEqual(record.source, .receiptOCR)
        XCTAssertTrue(record.isVerified)
        let receiptId = try XCTUnwrap(record.receiptId)
        let receipt = try XCTUnwrap(receipts.fetch(id: receiptId))
        XCTAssertEqual(receipt.reviewStatus, .reviewed)
        XCTAssertEqual(receipt.extractedTotalMinorUnits, 839)
        XCTAssertEqual(receipt.imageFingerprint, ImageFingerprint.string(42))
        XCTAssertEqual(receipts.imageData(forReceipt: receiptId), jpeg)
        XCTAssertEqual(try transactions.allRecords().count, 1)
    }

    func testReceiptIsNotCountedAsSeparateSpending() throws {
        let kinds = try ReferenceDataRepository(context: persistence.context).categoryKinds()
        let record = try receipts.saveNewTransaction(from: draft(), receipt: receiptImport(), categoryKinds: kinds)
        let summary = FinanceCalculationService().summary(of: try transactions.allRecords(),
                                                          in: Calendar.current.monthRange(containing: record.transactionDate),
                                                          currencyCode: "USD")
        XCTAssertEqual(summary.expenseMinorUnits, 839)
    }

    func testInvalidDraftWritesNothing() throws {
        XCTAssertThrowsError(try receipts.saveNewTransaction(from: draft(""), receipt: receiptImport(), categoryKinds: [:]))
        XCTAssertEqual(try storage.orphanedPaths(referenced: []), [])
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<Receipt>()), 0)
        XCTAssertEqual(try transactions.allRecords().count, 0)
    }

    func testLinkReceiptToExistingTransaction() throws {
        let existing = try transactions.save(draft(), categoryKinds: [:])
        try receipts.link(receipt: receiptImport(), toTransaction: existing.id)
        let updated = try XCTUnwrap(transactions.fetch(id: existing.id))
        XCTAssertNotNil(updated.receiptId)
        XCTAssertEqual(try transactions.allRecords().count, 1, "Linking must not create a second expense")
        XCTAssertThrowsError(try receipts.link(receipt: receiptImport(), toTransaction: existing.id)) {
            XCTAssertEqual($0 as? RepositoryError, .receiptAlreadyAttached)
        }
    }

    func testFingerprintsAreListedForDuplicateChecks() throws {
        try receipts.saveNewTransaction(from: draft(), receipt: receiptImport(), categoryKinds: [:])
        XCTAssertEqual(try receipts.fingerprints().map(\.fingerprint), [ImageFingerprint.string(42)])
    }
}
