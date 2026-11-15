# Architecture

## Overview

- **UI:** SwiftUI with an MVVM-style split. Views read live data with `@Query` and call repositories to change it.
  Form state and filtering live in pure value types (`TransactionDraft`, `TransactionFilter`), not in views.
- **Persistence:** SwiftData with a single local store. `cloudKitDatabase: .none` is set explicitly.
- **Dependency injection:** `AppContainer` (`@Observable`, `@MainActor`) holds `PersistenceService`, the repositories and
  `FinanceCalculationService`. It is injected with `.environment(...)`, and tests build their own in-memory containers.

```
View ──@Query──▶ SwiftData (read)
 │
 └─▶ Repository (TransactionRepository / ReferenceDataRepository) ──▶ ModelContext.save()
 │
 └─▶ FinanceCalculationService (pure, on TransactionRecord snapshots)
```

## Data model

| Model | Notes |
|---|---|
| `MoneyTransaction` | Lives in `Transaction.swift`. Renamed to avoid a clash with `SwiftUI.Transaction`. |
| `SpendingCategory` | Lives in `Category.swift`. Renamed to avoid the Objective-C `Category` typedef. |
| `PaymentMethod` | Stores only the last four digits, never a full number. Apple Pay can link to the card behind it. |
| `Receipt` | Image file in Application Support; the record holds only a relative path. |
| `RecurringBill` | An obligation only. It is never counted as spending. |
| `Budget`, `AppSettings` | `AppSettings` is a single row. |

- **Enums:** stored as raw `String` values with typed computed accessors.
- **Snapshots:** each model has a matching `Codable` `*Record` value type where needed. `TransactionRecord` is what calculations use.
- **Schema versioning:** `MyMoneySchemaV1` plus `MyMoneyMigrationPlan`. For V2, copy the V1 models into the schema enum as
  frozen nested types, then add a `MigrationStage`. Phase 2 added `transferDestinationPaymentMethodId` with a default value.
  No version has shipped yet, so this stays in V1.

## Financial rules

1. **Money storage:** amounts are `Int64` minor units using ISO 4217 exponents (JPY 0, KWD 3, others 2).
   Conversions go through `Decimal`, and money is never stored as a `Double`. Charts may convert to `Double` only for plotting.
2. **Direction:** amounts are always non-negative magnitudes, and `transactionType` gives the direction. `isRefund` reverses the
   amount within its bucket: a refunded expense lowers expenses, and a reversed income lowers income.
3. **What counts:** only `income` and `expense` count toward cash flow. `transfer` and `adjustment` never do.
4. **Credit cards:** a purchase on a card is an `expense`, counted on the day of the purchase. Paying the card bill is a `transfer`
   from the bank account to the card, so it isn't counted again. The editor warns when an expense looks like a card payment and
   offers a one-tap switch to Transfer. It never changes the data without the user's action.
5. **Date ranges:** ranges include their start and exclude their end, and are built with the user's `Calendar`.
   Calculations use `transactionDate`, never `createdAt`.
6. **Currencies:** summaries include only the selected currency. Other currencies are counted and reported as excluded, never converted.
7. **Net cash flow:** income minus expenses. It is never presented as a balance or net worth.
8. **Bills and receipts:** neither is ever summed as spending.

## Data safety

- **Category delete:** deleting a category that is in use requires a reassignment (move to a category of the same kind, or leave
  uncategorized). Budgets for the deleted category are deactivated, not deleted.
- **Payment method delete:** a payment method with history can only be deactivated, so past records keep it.
- **Transaction delete:** deleting a transaction always asks for confirmation. Duplicating opens an unsaved draft.
- **Store errors:** on a store-open failure the app shows an error. It never resets the store.

## Future: split transactions

A parent transaction holds the total, and child `TransactionSplit` rows (category, amount) add up to it.
Category totals will come from the children, while cash flow counts the parent once.
