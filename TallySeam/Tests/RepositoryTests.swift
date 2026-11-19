import Foundation
import SwiftData
import XCTest
@testable import TallySeam

/// In-memory SwiftData tests for Phase 2 repositories. Synthetic data only.
@MainActor
final class RepositoryTests: XCTestCase {
    private var persistence: PersistenceService!
    private var transactions: TransactionRepository!
    private var reference: ReferenceDataRepository!

    override func setUp() async throws {
        persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        transactions = TransactionRepository(context: persistence.context)
        reference = ReferenceDataRepository(context: persistence.context)
    }

    private func category(_ name: String) throws -> SpendingCategory {
        try XCTUnwrap(persistence.context.fetch(FetchDescriptor<SpendingCategory>()).first { $0.name == name })
    }

    private func expenseDraft(_ amount: String, category: UUID?) -> TransactionDraft {
        var d = TransactionDraft(currencyCode: "USD")
        d.title = "Synthetic"; d.amountText = amount; d.categoryId = category
        return d
    }

    func testAddEditDeleteTransaction() throws {
        let kinds = try reference.categoryKinds()
        let saved = try transactions.save(expenseDraft("10.00", category: nil), categoryKinds: kinds)

        var edit = TransactionDraft(editing: saved)
        edit.amountText = "25.50"
        try transactions.save(edit, categoryKinds: kinds)
        let all = try transactions.allRecords()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.amountMinorUnits, 2_550)
        XCTAssertEqual(all.first?.createdAt, saved.createdAt)

        try transactions.delete(id: saved.id)
        XCTAssertTrue(try transactions.allRecords().isEmpty)
        XCTAssertThrowsError(try transactions.delete(id: saved.id))
    }

    func testDuplicateCreatesSecondTransaction() throws {
        let kinds = try reference.categoryKinds()
        let original = try transactions.save(expenseDraft("4.00", category: nil), categoryKinds: kinds)
        try transactions.save(.duplicating(original), categoryKinds: kinds)
        XCTAssertEqual(try transactions.allRecords().count, 2)
    }

    func testDeletingUsedCategoryRequiresReassignment() throws {
        let kinds = try reference.categoryKinds()
        let restaurants = try category("Restaurants"), groceries = try category("Groceries")
        try transactions.save(expenseDraft("8.00", category: restaurants.id), categoryKinds: kinds)

        XCTAssertThrowsError(try reference.deleteCategory(id: restaurants.id, reassignment: nil)) {
            XCTAssertEqual($0 as? RepositoryError, .categoryInUse(transactions: 1))
        }
        try reference.deleteCategory(id: restaurants.id, reassignment: .moveTo(groceries.id))
        XCTAssertEqual(try transactions.allRecords().first?.categoryId, groceries.id)
    }

    func testReassignmentTargetMustMatchKind() throws {
        let kinds = try reference.categoryKinds()
        let restaurants = try category("Restaurants"), salary = try category("Salary")
        try transactions.save(expenseDraft("8.00", category: restaurants.id), categoryKinds: kinds)
        XCTAssertThrowsError(try reference.deleteCategory(id: restaurants.id, reassignment: .moveTo(salary.id))) {
            XCTAssertEqual($0 as? RepositoryError, .invalidReassignmentTarget)
        }
        XCTAssertEqual(try transactions.allRecords().first?.categoryId, restaurants.id, "Nothing changes on failure")
    }

    func testLeaveUncategorizedAndBudgetDeactivated() throws {
        let kinds = try reference.categoryKinds()
        let travel = try category("Travel")
        try transactions.save(expenseDraft("300", category: travel.id), categoryKinds: kinds)
        let budget = Budget(categoryId: travel.id, amountMinorUnits: 50_000, effectiveStartMonth: .now)
        persistence.context.insert(budget)
        try persistence.context.save()

        try reference.deleteCategory(id: travel.id, reassignment: .leaveUncategorized)
        XCTAssertNil(try transactions.allRecords().first?.categoryId)
        XCTAssertFalse(budget.isActive)
        XCTAssertEqual(try persistence.context.fetchCount(FetchDescriptor<Budget>()), 1, "Budget kept, not deleted")
    }

    func testUnusedCategoryDeletesWithoutReassignment() throws {
        let custom = try reference.createCategory(name: "Hobbies", symbol: "paintbrush", colorIdentifier: "pink", kind: .expense)
        try reference.deleteCategory(id: custom.id, reassignment: nil)
        XCTAssertNil(try persistence.context.fetch(FetchDescriptor<SpendingCategory>()).first { $0.name == "Hobbies" })
    }

    func testPaymentMethodLastFourNeverStoresFullNumber() throws {
        let m = try reference.createPaymentMethod(name: "Card", type: .creditCard, nickname: nil, lastFour: "4111111111111111", underlyingId: nil)
        XCTAssertNil(m.lastFourDigits)
    }

    func testUsedPaymentMethodCannotBeDeleted() throws {
        let card = try reference.createPaymentMethod(name: "Card", type: .creditCard, nickname: nil, lastFour: "1234", underlyingId: nil)
        var d = expenseDraft("20", category: nil)
        d.paymentMethodId = card.id
        try transactions.save(d, categoryKinds: try reference.categoryKinds())
        XCTAssertThrowsError(try reference.deletePaymentMethod(id: card.id)) {
            XCTAssertEqual($0 as? RepositoryError, .paymentMethodInUse(transactions: 1))
        }
    }

    /// End-to-end double-count check through the real persistence layer:
    /// $120 of card purchases + a $120 card repayment transfer = $120 of spending.
    func testCreditCardRepaymentNotDoubleCounted() throws {
        let kinds = try reference.categoryKinds()
        let card = try reference.createPaymentMethod(name: "Card", type: .creditCard, nickname: nil, lastFour: nil, underlyingId: nil)
        let bank = try reference.createPaymentMethod(name: "Checking", type: .bankTransfer, nickname: nil, lastFour: nil, underlyingId: nil)
        let date = Date.now

        for amount in ["70.00", "50.00"] {
            var p = expenseDraft(amount, category: nil); p.paymentMethodId = card.id; p.date = date
            try transactions.save(p, categoryKinds: kinds)
        }
        var repay = TransactionDraft(currencyCode: "USD", date: date)
        repay.type = .transfer; repay.title = "Card payment"; repay.amountText = "120.00"
        repay.paymentMethodId = bank.id; repay.transferDestinationPaymentMethodId = card.id
        try transactions.save(repay, categoryKinds: kinds)

        let summary = FinanceCalculationService().summary(of: try transactions.allRecords(),
                                                          in: Calendar.current.monthRange(containing: date), currencyCode: "USD")
        XCTAssertEqual(summary.expenseMinorUnits, 12_000)
        XCTAssertEqual(summary.transactionCount, 3)
    }
}
