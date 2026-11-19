import Foundation
import SwiftData

enum CategoryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case income, expense
    var id: String { rawValue }
    var displayName: String { self == .income ? "Income" : "Expense" }
}

/// Named `SpendingCategory` because `Category` collides with the Objective-C runtime typedef.
@Model
final class SpendingCategory {
    @Attribute(.unique) var id: UUID
    var name: String
    var symbol: String
    var colorIdentifier: String
    var kindRaw: String
    var isSystemCategory: Bool
    var displayOrder: Int

    init(id: UUID = UUID(), name: String, symbol: String, colorIdentifier: String, kind: CategoryKind,
         isSystemCategory: Bool, displayOrder: Int) {
        self.id = id; self.name = name; self.symbol = symbol; self.colorIdentifier = colorIdentifier
        self.kindRaw = kind.rawValue; self.isSystemCategory = isSystemCategory; self.displayOrder = displayOrder
    }

    var kind: CategoryKind {
        get { CategoryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
}

/// System categories seeded on first launch. These are configuration, not demo data.
enum DefaultCategories {
    static let expense: [(name: String, symbol: String, color: String)] = [
        ("Housing", "house.fill", "brown"), ("Groceries", "cart.fill", "green"),
        ("Restaurants", "fork.knife", "orange"), ("Transportation", "car.fill", "blue"),
        ("Fuel", "fuelpump.fill", "red"), ("Utilities", "bolt.fill", "yellow"),
        ("Shopping", "bag.fill", "pink"), ("Healthcare", "cross.case.fill", "teal"),
        ("Entertainment", "film.fill", "purple"), ("Subscriptions", "repeat.circle.fill", "indigo"),
        ("Insurance", "shield.fill", "cyan"), ("Education", "book.fill", "mint"),
        ("Travel", "airplane", "blue"), ("Other", "ellipsis.circle.fill", "gray"),
    ]
    static let income: [(name: String, symbol: String, color: String)] = [
        ("Salary", "briefcase.fill", "green"), ("Freelance", "laptopcomputer", "teal"),
        ("Reimbursement", "arrow.uturn.backward.circle.fill", "blue"), ("Interest", "percent", "mint"),
        ("Other Income", "plus.circle.fill", "gray"),
    ]

    static func makeAll() -> [SpendingCategory] {
        expense.enumerated().map { i, c in
            SpendingCategory(name: c.name, symbol: c.symbol, colorIdentifier: c.color, kind: .expense, isSystemCategory: true, displayOrder: i)
        } + income.enumerated().map { i, c in
            SpendingCategory(name: c.name, symbol: c.symbol, colorIdentifier: c.color, kind: .income, isSystemCategory: true, displayOrder: i)
        }
    }
}
