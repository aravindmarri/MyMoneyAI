import Foundation
import SwiftData

/// What to do with transactions (and bills) that reference a category being deleted.
enum CategoryReassignment: Equatable, Sendable {
    case moveTo(UUID)
    case leaveUncategorized
}

struct CategoryUsage: Equatable, Sendable {
    var transactions = 0
    var bills = 0
    var budgets = 0
    var isUnused: Bool { transactions == 0 && bills == 0 && budgets == 0 }
}

/// Manages categories and payment methods. Never removes references silently:
/// deleting something in use requires an explicit choice from the user.
@MainActor
final class ReferenceDataRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    // MARK: Categories

    func categoryKinds() throws -> [UUID: CategoryKind] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<SpendingCategory>()).map { ($0.id, $0.kind) })
    }

    @discardableResult
    func createCategory(name: String, symbol: String, colorIdentifier: String, kind: CategoryKind) throws -> SpendingCategory {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw RepositoryError.invalidName }
        let order = (try context.fetch(FetchDescriptor<SpendingCategory>()).filter { $0.kind == kind }.map(\.displayOrder).max() ?? -1) + 1
        let c = SpendingCategory(name: n, symbol: symbol, colorIdentifier: colorIdentifier, kind: kind,
                                 isSystemCategory: false, displayOrder: order)
        context.insert(c)
        try context.save()
        return c
    }

    /// Kind cannot change after creation: existing transactions depend on it.
    func updateCategory(_ c: SpendingCategory, name: String, symbol: String, colorIdentifier: String) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw RepositoryError.invalidName }
        c.name = n; c.symbol = symbol; c.colorIdentifier = colorIdentifier
        try context.save()
    }

    func usage(ofCategory id: UUID) throws -> CategoryUsage {
        CategoryUsage(
            transactions: try context.fetch(FetchDescriptor<MoneyTransaction>()).filter { $0.categoryId == id }.count,
            bills: try context.fetch(FetchDescriptor<RecurringBill>()).filter { $0.categoryId == id }.count,
            budgets: try context.fetch(FetchDescriptor<Budget>()).filter { $0.categoryId == id }.count
        )
    }

    /// Deletes a category. If it is in use, `reassignment` is required:
    /// - transactions and bills move to the target (same kind) or become uncategorized;
    /// - budgets for the deleted category are deactivated (kept, not deleted) so the
    ///   target's own budget is never silently changed.
    func deleteCategory(id: UUID, reassignment: CategoryReassignment?) throws {
        let categories = try context.fetch(FetchDescriptor<SpendingCategory>())
        guard let category = categories.first(where: { $0.id == id }) else { throw RepositoryError.notFound }
        let use = try usage(ofCategory: id)

        var newCategoryId: UUID? = nil
        if !use.isUnused {
            guard let reassignment else { throw RepositoryError.categoryInUse(transactions: use.transactions) }
            if case .moveTo(let target) = reassignment {
                guard target != id, let t = categories.first(where: { $0.id == target }), t.kind == category.kind else {
                    throw RepositoryError.invalidReassignmentTarget
                }
                newCategoryId = target
            }
        }

        let now = Date.now
        for t in try context.fetch(FetchDescriptor<MoneyTransaction>()) where t.categoryId == id {
            t.categoryId = newCategoryId
            t.updatedAt = now
        }
        for b in try context.fetch(FetchDescriptor<RecurringBill>()) where b.categoryId == id {
            b.categoryId = newCategoryId
        }
        for b in try context.fetch(FetchDescriptor<Budget>()) where b.categoryId == id {
            b.isActive = false
            b.categoryId = nil
        }
        context.delete(category)
        try context.save()
    }

    // MARK: Payment methods

    @discardableResult
    func createPaymentMethod(name: String, type: PaymentMethodType, nickname: String?, lastFour: String?,
                             underlyingId: UUID?) throws -> PaymentMethod {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw RepositoryError.invalidName }
        let m = PaymentMethod(name: n, type: type, accountNickname: Self.clean(nickname), lastFourDigits: lastFour,
                              underlyingPaymentMethodId: type == .applePay ? underlyingId : nil)
        context.insert(m)
        try context.save()
        return m
    }

    func updatePaymentMethod(_ m: PaymentMethod, name: String, type: PaymentMethodType, nickname: String?,
                             lastFour: String?, underlyingId: UUID?, isActive: Bool) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw RepositoryError.invalidName }
        m.name = n
        m.type = type
        m.accountNickname = Self.clean(nickname)
        m.lastFourDigits = PaymentMethod.sanitizedLastFour(lastFour)
        m.underlyingPaymentMethodId = (type == .applePay && underlyingId != m.id) ? underlyingId : nil
        m.isActive = isActive
        try context.save()
    }

    func usage(ofPaymentMethod id: UUID) throws -> Int {
        try context.fetch(FetchDescriptor<MoneyTransaction>())
            .filter { $0.paymentMethodId == id || $0.transferDestinationPaymentMethodId == id }.count
    }

    /// Deletes an unused payment method. Methods with history must be deactivated instead,
    /// so past transactions keep showing how they were paid.
    func deletePaymentMethod(id: UUID) throws {
        guard let m = try context.fetch(FetchDescriptor<PaymentMethod>()).first(where: { $0.id == id }) else {
            throw RepositoryError.notFound
        }
        let used = try usage(ofPaymentMethod: id)
        guard used == 0 else { throw RepositoryError.paymentMethodInUse(transactions: used) }
        for other in try context.fetch(FetchDescriptor<PaymentMethod>()) where other.underlyingPaymentMethodId == id {
            other.underlyingPaymentMethodId = nil
        }
        for b in try context.fetch(FetchDescriptor<RecurringBill>()) where b.paymentMethodId == id {
            b.paymentMethodId = nil
        }
        context.delete(m)
        try context.save()
    }

    /// Creates several payment methods with one save. Returns how many were added.
    @discardableResult
    func createPaymentMethods(_ items: [AccountSetupItem], existingNames: [String]) throws -> Int {
        let toCreate = try AccountSetup.itemsToCreate(items, existingNames: existingNames)
        for item in toCreate {
            context.insert(PaymentMethod(name: item.name, type: item.type,
                                         lastFourDigits: item.lastFour.isEmpty ? nil : item.lastFour))
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return toCreate.count
    }

    private static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}
