import Foundation
import SwiftData

/// Schema versioning.
///
/// The latest version references the live model types. Each older version keeps frozen copies of
/// the models that changed after it, so SwiftData can recognise stores written by older app
/// versions and migrate them. To change a model: copy its current definition into the latest
/// version's enum as a nested type, add a new version that references the live type, and append a
/// MigrationStage (lightweight where possible). Never edit a frozen copy.
enum TallySeamSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [TallySeamSchemaV1.MoneyTransaction.self, SpendingCategory.self, PaymentMethod.self, Receipt.self,
         RecurringBill.self, Budget.self, AppSettings.self]
    }

    /// MoneyTransaction exactly as shipped in schema 1.0.0 (app builds up to 1.0 (16)). Frozen.
    @Model
    final class MoneyTransaction {
        @Attribute(.unique) var id: UUID
        var transactionDate: Date
        var createdAt: Date
        var updatedAt: Date
        var amountMinorUnits: Int64
        var currencyCode: String
        var merchant: String?
        var title: String
        var notes: String?
        var transactionTypeRaw: String
        var categoryId: UUID?
        var paymentMethodId: UUID?
        var receiptId: UUID?
        var recurringBillId: UUID?
        var sourceRaw: String
        var isVerified: Bool
        var transferGroupId: UUID?
        var isRefund: Bool = false
        var transferDestinationPaymentMethodId: UUID? = nil

        init(id: UUID, transactionDate: Date, amountMinorUnits: Int64, currencyCode: String, title: String,
             transactionTypeRaw: String, isRefund: Bool = false) {
            self.id = id; self.transactionDate = transactionDate; self.createdAt = transactionDate; self.updatedAt = transactionDate
            self.amountMinorUnits = amountMinorUnits; self.currencyCode = currencyCode; self.title = title
            self.transactionTypeRaw = transactionTypeRaw; self.sourceRaw = TransactionSource.manual.rawValue
            self.isVerified = true; self.isRefund = isRefund
        }
    }
}

/// 2.0.0: MoneyTransaction gains `countedMonth` (count a transaction in another month, e.g. a
/// November salary paid in late October). Optional with no value, so existing rows keep their meaning.
enum TallySeamSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [MoneyTransaction.self, SpendingCategory.self, PaymentMethod.self, Receipt.self,
         RecurringBill.self, Budget.self, AppSettings.self]
    }
}

/// 3.0.0: statement import and reconciliation. Adds new models only (no existing model changes),
/// so 2.0.0 keeps referencing the live types and a lightweight stage adds the new tables.
enum TallySeamSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        TallySeamSchemaV2.models + [FinancialAccount.self, ImportSession.self, ImportedStatement.self,
                                  StatementTransaction.self, ReconciliationMatch.self, MerchantAlias.self]
    }
}

/// The schema every container opens with.
typealias TallySeamCurrentSchema = TallySeamSchemaV3

enum TallySeamMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TallySeamSchemaV1.self, TallySeamSchemaV2.self, TallySeamSchemaV3.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: TallySeamSchemaV1.self, toVersion: TallySeamSchemaV2.self),
         .lightweight(fromVersion: TallySeamSchemaV2.self, toVersion: TallySeamSchemaV3.self)]
    }
}
