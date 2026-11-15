import Foundation
import SwiftData

enum RepositoryError: Error, Equatable, LocalizedError {
    case notFound
    case categoryInUse(transactions: Int)
    case invalidReassignmentTarget
    case paymentMethodInUse(transactions: Int)
    case invalidName
    case receiptAlreadyAttached

    var errorDescription: String? {
        switch self {
        case .receiptAlreadyAttached: "That transaction already has a receipt."
        case .notFound: "The item no longer exists."
        case .categoryInUse(let n): "This category is used by \(n) transaction(s). Choose where to move them first."
        case .invalidReassignmentTarget: "Choose a different category of the same type."
        case .paymentMethodInUse(let n): "This payment method is used by \(n) transaction(s). Deactivate it instead to keep history intact."
        case .invalidName: "Enter a name."
        }
    }
}

/// Create, update, delete and duplicate transactions. Every change is saved immediately.
@MainActor
final class TransactionRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func fetch(id: UUID) throws -> MoneyTransaction? {
        var d = FetchDescriptor<MoneyTransaction>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    func allRecords() throws -> [TransactionRecord] {
        try context.fetch(FetchDescriptor<MoneyTransaction>()).map(\.record)
    }

    /// Inserts a new transaction or updates the one being edited.
    @discardableResult
    func save(_ draft: TransactionDraft, categoryKinds: [UUID: CategoryKind], now: Date = .now) throws -> TransactionRecord {
        let record = try draft.makeRecord(categoryKinds: categoryKinds, now: now)
        if let id = draft.editingId {
            guard let existing = try fetch(id: id) else { throw RepositoryError.notFound }
            existing.apply(record)
        } else {
            context.insert(MoneyTransaction(record: record))
        }
        try context.save()
        return record
    }

    /// Deletes one transaction. Callers must confirm with the user first.
    /// An attached receipt record is kept (receipt cleanup is handled with receipts in Phase 4).
    func delete(id: UUID) throws {
        guard let t = try fetch(id: id) else { throw RepositoryError.notFound }
        context.delete(t)
        try context.save()
    }
}
