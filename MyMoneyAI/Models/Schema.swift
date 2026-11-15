import Foundation
import SwiftData

/// Schema versioning. V1 references the live model types. When V2 is introduced, copy the V1
/// model definitions into this enum as nested (frozen) types, add MyMoneySchemaV2, and append
/// a MigrationStage (lightweight where possible, custom where data must be transformed).
enum MyMoneySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [MoneyTransaction.self, SpendingCategory.self, PaymentMethod.self, Receipt.self,
         RecurringBill.self, Budget.self, AppSettings.self]
    }
}

enum MyMoneyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MyMoneySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
