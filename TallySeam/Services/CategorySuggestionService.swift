import Foundation

/// Merchant name normalization shared by category suggestions and duplicate detection.
enum MerchantName {
    /// "STARBUCKS #1234" → "starbucks", "Trader Joe's" → "trader joe s", "Café Olé" → "cafe ole".
    static func normalize(_ s: String?) -> String {
        guard let s else { return "" }
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let spaced = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return spaced.split(separator: " ")
            .filter { !$0.allSatisfy(\.isNumber) }
            .joined(separator: " ")
    }

    /// Whole-word containment, so "bp" matches "bp station" but not "bpm".
    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        " \(text) ".contains(" \(phrase) ")
    }
}

/// A category the suggester may choose from (decoupled from SwiftData for testing).
struct CategoryOption: Sendable, Hashable {
    var id: UUID
    var name: String
    var kind: CategoryKind
}

struct CategorySuggestion: Equatable, Sendable {
    enum Source: String, Sendable {
        case history, merchantDirectory, keyword
        var explanation: String {
            switch self {
            case .history: "Based on how you categorized this merchant before"
            case .merchantDirectory: "Based on the merchant name"
            case .keyword: "Based on words on the receipt"
            }
        }
    }
    var categoryId: UUID
    var source: Source
}

/// Replaceable suggestion engine. A future on-device language model can implement this protocol
/// and fall back to the heuristic implementation.
protocol CategorySuggesting: Sendable {
    func suggest(merchant: String?, receiptText: String?, kind: CategoryKind,
                 categories: [CategoryOption], history: [TransactionRecord]) -> CategorySuggestion?
}

/// Local, deterministic suggestions: (1) the user's own past choices for this merchant,
/// (2) a built-in merchant directory, (3) keywords in the merchant name or receipt header.
struct HeuristicCategorySuggestionService: CategorySuggesting {
    /// Normalized merchant phrase → default category name.
    static let merchantDirectory: [String: String] = [
        "uber eats": "Restaurants", "doordash": "Restaurants", "grubhub": "Restaurants",
        "starbucks": "Restaurants", "dunkin": "Restaurants", "mcdonald s": "Restaurants", "mcdonalds": "Restaurants",
        "chipotle": "Restaurants", "domino s": "Restaurants", "pizza hut": "Restaurants", "kfc": "Restaurants",
        "taco bell": "Restaurants", "burger king": "Restaurants", "wendy s": "Restaurants", "panera": "Restaurants",
        "subway": "Restaurants", "chick fil a": "Restaurants",
        "walmart": "Groceries", "costco": "Groceries", "kroger": "Groceries", "safeway": "Groceries",
        "whole foods": "Groceries", "trader joe s": "Groceries", "aldi": "Groceries", "publix": "Groceries",
        "albertsons": "Groceries", "wegmans": "Groceries", "sprouts": "Groceries",
        "target": "Shopping", "amazon": "Shopping", "best buy": "Shopping", "ikea": "Shopping",
        "home depot": "Shopping", "lowe s": "Shopping", "macy s": "Shopping",
        "shell": "Fuel", "chevron": "Fuel", "exxon": "Fuel", "mobil": "Fuel", "bp": "Fuel", "texaco": "Fuel",
        "arco": "Fuel", "valero": "Fuel", "sunoco": "Fuel", "speedway": "Fuel",
        "uber": "Transportation", "lyft": "Transportation",
        "netflix": "Subscriptions", "spotify": "Subscriptions", "hulu": "Subscriptions", "disney plus": "Subscriptions",
        "youtube premium": "Subscriptions", "icloud": "Subscriptions",
        "cvs": "Healthcare", "walgreens": "Healthcare", "rite aid": "Healthcare",
        "amc": "Entertainment", "regal": "Entertainment",
        "delta": "Travel", "united airlines": "Travel", "american airlines": "Travel", "southwest": "Travel",
        "marriott": "Travel", "hilton": "Travel", "airbnb": "Travel", "expedia": "Travel",
        "comcast": "Utilities", "xfinity": "Utilities", "verizon": "Utilities", "t mobile": "Utilities",
    ]

    /// Keyword → category name (matched as whole words in the merchant name and receipt header).
    static let keywords: [(String, String)] = [
        ("restaurant", "Restaurants"), ("cafe", "Restaurants"), ("coffee", "Restaurants"), ("grill", "Restaurants"),
        ("pizza", "Restaurants"), ("bistro", "Restaurants"), ("diner", "Restaurants"), ("bakery", "Restaurants"),
        ("kitchen", "Restaurants"), ("taqueria", "Restaurants"),
        ("grocery", "Groceries"), ("market", "Groceries"), ("supermarket", "Groceries"), ("foods", "Groceries"),
        ("gas", "Fuel"), ("fuel", "Fuel"), ("petrol", "Fuel"), ("diesel", "Fuel"),
        ("pharmacy", "Healthcare"), ("rx", "Healthcare"), ("clinic", "Healthcare"), ("dental", "Healthcare"),
        ("medical", "Healthcare"), ("hospital", "Healthcare"),
        ("parking", "Transportation"), ("taxi", "Transportation"), ("transit", "Transportation"), ("toll", "Transportation"),
        ("electric", "Utilities"), ("utility", "Utilities"), ("internet", "Utilities"), ("energy", "Utilities"),
        ("hotel", "Travel"), ("airline", "Travel"), ("airport", "Travel"), ("resort", "Travel"),
        ("cinema", "Entertainment"), ("theater", "Entertainment"), ("theatre", "Entertainment"), ("movies", "Entertainment"),
        ("tuition", "Education"), ("bookstore", "Education"),
        ("insurance", "Insurance"),
    ]

    func suggest(merchant: String?, receiptText: String?, kind: CategoryKind,
                 categories: [CategoryOption], history: [TransactionRecord]) -> CategorySuggestion? {
        let options = categories.filter { $0.kind == kind }
        let validIds = Set(options.map(\.id))
        let m = MerchantName.normalize(merchant)

        if !m.isEmpty {
            let previous = history
                .filter { $0.categoryId.map(validIds.contains) == true && MerchantName.normalize($0.merchant ?? $0.title) == m }
                .max { $0.transactionDate < $1.transactionDate }
            if let id = previous?.categoryId { return CategorySuggestion(categoryId: id, source: .history) }

            for key in Self.merchantDirectory.keys.sorted(by: { $0.count > $1.count }) where MerchantName.containsPhrase(m, key) {
                if let id = Self.category(named: Self.merchantDirectory[key], in: options) {
                    return CategorySuggestion(categoryId: id, source: .merchantDirectory)
                }
            }
        }

        // Header only: item names further down ("bottled water") would mislead keyword matching.
        let header = (receiptText ?? "").components(separatedBy: .newlines).prefix(3).joined(separator: " ")
        let haystack = MerchantName.normalize(m + " " + header)
        for (word, name) in Self.keywords where MerchantName.containsPhrase(haystack, word) {
            if let id = Self.category(named: name, in: options) { return CategorySuggestion(categoryId: id, source: .keyword) }
        }
        return nil
    }

    private static func category(named name: String?, in options: [CategoryOption]) -> UUID? {
        guard let name else { return nil }
        return options.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }
}
