# MyMoney AI — Phase 1 (Foundation)

Offline, local-first iPhone finance tracker. SwiftUI + SwiftData, iOS 17+, no third-party packages, no network.

## Build status

**Not compiled yet.** This source was written on a Windows machine with no Xcode or Swift toolchain,
so nothing here has been built or tested. Run the steps below on a Mac before starting Phase 2.

## Build on a Mac

Requires Xcode 16 or later (Swift Testing is used) and [XcodeGen](https://github.com/yonaskolb/XcodeGen),
which generates the `.xcodeproj` from `project.yml`. XcodeGen is a build-time tool only, not an app dependency.

```bash
brew install xcodegen
```

```bash
cd MyMoneyAI && xcodegen generate
```

```bash
xcodebuild -project MyMoneyAI.xcodeproj -scheme MyMoneyAI -destination 'platform=iOS Simulator,name=iPhone 16' build test
```

To run on a device, open `MyMoneyAI.xcodeproj`, choose your team under Signing & Capabilities, and run.

## Architecture decisions

- **Model names:** `MoneyTransaction` and `SpendingCategory` (files are still `Transaction.swift` and `Category.swift`).
  This avoids clashes with `SwiftUI.Transaction` and the Objective-C `Category` typedef.
- **Money:** stored as `Int64` minor units. Currency exponents follow ISO 4217, and conversions go through `Decimal`.
  Amounts are always positive; `transactionType` sets the direction and `isRefund` reverses it within that type.
- **Calculations:** these run on `TransactionRecord` value snapshots, not live SwiftData objects, so they can be tested without a database.
  Ranges are start-inclusive and end-exclusive. Transfers and adjustments are never counted, and other currencies are left out rather than converted.
- **Persistence:** CloudKit is explicitly off (`cloudKitDatabase: .none`). The store sits in Application Support/Store and uses
  `completeUntilFirstUserAuthentication` data protection. `VersionedSchema` V1 plus a migration plan are in place.
- **Seeding:** only the system categories and one settings row are created. There are no sample transactions.
- **Concurrency:** Swift 5 language mode with `SWIFT_STRICT_CONCURRENCY=complete`. Concurrency problems show up as warnings, and these should
  be cleared before switching to Swift 6 mode.
- **Bills:** bills are obligations, and the calculation service never reads them.
