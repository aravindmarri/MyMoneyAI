import Foundation
import Observation

enum AppTab: Hashable {
    case home, transactions, scan, reports, settings
}

/// Dependency container injected through the SwiftUI environment.
@MainActor
@Observable
final class AppContainer {
    let persistence: PersistenceService
    let finance: FinanceCalculationService
    let transactions: TransactionRepository
    let referenceData: ReferenceDataRepository
    let receipts: ReceiptRepository
    let textRecognizer: any ReceiptTextRecognizing
    let categorySuggester: any CategorySuggesting
    var selectedTab: AppTab = .home

    init(persistence: PersistenceService,
         receiptStorage: ReceiptStorageService,
         finance: FinanceCalculationService = FinanceCalculationService(),
         textRecognizer: any ReceiptTextRecognizing = VisionReceiptOCRService(),
         categorySuggester: any CategorySuggesting = HeuristicCategorySuggestionService()) {
        self.persistence = persistence
        self.finance = finance
        self.transactions = TransactionRepository(context: persistence.context)
        self.referenceData = ReferenceDataRepository(context: persistence.context)
        self.receipts = ReceiptRepository(context: persistence.context, storage: receiptStorage)
        self.textRecognizer = textRecognizer
        self.categorySuggester = categorySuggester
    }

    static func live() throws -> AppContainer {
        let persistence = try PersistenceService()
        try persistence.seedDefaultsIfNeeded()
        let container = AppContainer(persistence: persistence, receiptStorage: try ReceiptStorageService.live())
        _ = try? container.receipts.removeOrphanedImages()
        return container
    }

    /// In-memory container for SwiftUI previews and tests. Contains only system categories.
    static func preview() -> AppContainer {
        // swiftlint:disable:next force_try
        let persistence = try! PersistenceService(inMemory: true)
        try? persistence.seedDefaultsIfNeeded()
        let storage = ReceiptStorageService(rootURL: FileManager.default.temporaryDirectory.appending(path: "MyMoneyAIPreview"))
        return AppContainer(persistence: persistence, receiptStorage: storage)
    }
}
