import Foundation
import SwiftData
import XCTest
@testable import MyMoneyAI

@MainActor
final class PersistenceTests: XCTestCase {
    func testSeedingIsIdempotentAndInsertsNoTransactions() throws {
        let p = try PersistenceService(inMemory: true)
        try p.seedDefaultsIfNeeded()
        try p.seedDefaultsIfNeeded()
        let expected = DefaultCategories.expense.count + DefaultCategories.income.count
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<SpendingCategory>()), expected)
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<AppSettings>()), 1)
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<MoneyTransaction>()), 0)
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<PaymentMethod>()), 0)
    }

    func testTransactionRoundTripPreservesValues() throws {
        let p = try PersistenceService(inMemory: true)
        let record = TransactionRecord(transactionDate: Date(timeIntervalSince1970: 1_700_000_000), amountMinorUnits: 123_456,
                                       merchant: "Synthetic Market", title: "Groceries", transactionType: .expense, isRefund: true)
        p.context.insert(MoneyTransaction(record: record))
        try p.context.save()

        let fetched = try XCTUnwrap(p.context.fetch(FetchDescriptor<MoneyTransaction>()).first)
        XCTAssertEqual(fetched.record, record)
    }

    func testDefaultSettings() throws {
        let p = try PersistenceService(inMemory: true)
        let s = try p.settings()
        XCTAssertEqual(s.preferredCurrencyCode, "USD")
        XCTAssertFalse(s.requireBiometricUnlock)
    }
}
