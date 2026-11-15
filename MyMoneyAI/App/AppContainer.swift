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
    var selectedTab: AppTab = .home

    init(persistence: PersistenceService, finance: FinanceCalculationService = FinanceCalculationService()) {
        self.persistence = persistence
        self.finance = finance
        self.transactions = TransactionRepository(context: persistence.context)
        self.referenceData = ReferenceDataRepository(context: persistence.context)
    }

    static func live() throws -> AppContainer {
        let persistence = try PersistenceService()
        try persistence.seedDefaultsIfNeeded()
        return AppContainer(persistence: persistence)
    }

    /// In-memory container for SwiftUI previews and tests. Contains only system categories.
    static func preview() -> AppContainer {
        // swiftlint:disable:next force_try
        let persistence = try! PersistenceService(inMemory: true)
        try? persistence.seedDefaultsIfNeeded()
        return AppContainer(persistence: persistence)
    }
}
