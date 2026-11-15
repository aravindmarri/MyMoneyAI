# Build Status

_Last updated: 2026-11-15_

Development happens on Windows. iOS builds and tests run on GitHub Actions (`.github/workflows/ios-build.yml`, `macos-15` runner, XcodeGen).

## Summary (CI run #9, commit `6e683b9`)

| Check | Result |
|---|---|
| iOS Simulator compile | **Pass** (GitHub Actions) |
| Automated tests | **Pass: 114 of 114** (0 failed, 0 skipped), Swift Testing and XCTest on the iOS Simulator |
| Unsigned device archive | **Pass.** `MyMoneyAI-unsigned-ipa` artifact (570 KB) |
| Run on a real iPhone | **Not done.** Needs re-signing with your Apple Account (see below) |
| Manual UI check (layout, VoiceOver, Dynamic Type, dark mode) | **Not done** |
| Airplane-mode check on a device | **Not done.** The code makes no network calls, and Vision OCR ran offline in the simulator test |
| Static source checks (`python tools/check_sources.py`) | **Pass:** 60 Swift files |

Run: https://github.com/aravindmarri/MyMoneyAI/actions/runs/43695508989

### CI history

| Run | Commit | Result | Notes |
|---|---|---|---|
| #2 | `bbd8fcd` | Fail | Missing `TransactionType.categoryKind`; the editor body was too complex to type-check |
| #3 | `e1d33a9` | **Pass** | First successful build; unsigned IPA produced |
| #4 | `947bd8d` | **Pass** | 60 of 60 tests (Phases 1–3) |
| #5 | `1e5dce1` | Fail | Tests called a main-actor method from a nonisolated context |
| #6 | `7e9f320` | Fail | Nested `#require` macro (the error wasn't annotated yet) |
| #7 | `67473bf` | Fail | Same error, now annotated |
| #8 | `045d4e8` | **Pass** | 98 of 98 tests (Phases 1–4) |
| #9 | `6e683b9` | **Pass** | 114 of 114 tests (Phases 1–5) |

## About the unsigned IPA

`MyMoneyAI-unsigned-ipa` is **not signed and cannot be installed on an iPhone as-is.** It must first be re-signed with your own Apple Account, for example with Sideloadly or AltStore. With a free Apple Account, apps signed this way expire after 7 days and must be re-signed. CI artifacts are kept for 14 days.

## Implemented features (compiled and covered by passing CI tests where noted)

**Phase 1:** foundation
- XcodeGen project (iOS 17, iPhone), SwiftData schema V1 with a migration plan, CloudKit off, store protected with iOS Data Protection
- First launch creates only the default categories and settings, with no sample data
- Five tabs with empty states

**Phase 2:** manual transactions
- Add, edit, delete (with confirmation), and duplicate (opens an unsaved copy)
- Search and filters
- Category and payment-method management; deleting a category in use requires reassigning its transactions; only the last four card digits are stored
- Credit-card repayments are recorded as transfers, with a warning when one is entered as an expense

**Phase 3:** dashboard and reports
- Category donut and 6-month cash-flow chart on the dashboard
- Reports: period presets and custom dates, monthly income vs expenses, category, payment-method and merchant breakdowns, daily trend, month-over-month comparison, year to date
- Each chart has accessibility labels and a "Show data" table

**Phase 4:** offline receipt scanning
- Import from Photos (including screenshots) or the camera
- Images are re-rendered and re-encoded, which strips metadata including GPS
- On-device Apple Vision text recognition, with labels and prices from separate columns put back on one line
- Deterministic parser for merchant, date, total, tax, discount and currency, each with a confidence level. It handles change and cash lines, labels and amounts on separate lines, discounts before or after the subtotal, tax rates, European number formats, and OCR misreads such as "T0TAL"
- Review screen: the image next to editable fields, with uncertain values flagged; nothing is saved until you tap Save; manual entry if OCR finds no text
- Duplicate warnings for the same or a similar image (perceptual hash) and for an expense with the same amount, day and merchant. You can save anyway or attach the receipt to the existing expense
- Images are stored in Application Support with complete file protection; image paths are validated, and files left by an interrupted save are cleaned up
- Category suggestions from your past choices for the merchant, then a built-in merchant directory, then header keywords
- Receipts appear on the transaction detail screen and are never counted as separate spending

**Phase 5:** bills and budgets
- Bill editor: name, optional expected amount (empty means it varies), currency, weekly, monthly, yearly or every N days, category and payment method used when paid, notes
- Due status by calendar day: overdue, due today, due within 7 days, upcoming, paused
- Record Payment either creates one expense linked to the bill or links an expense you already recorded (for example from a receipt), so it isn't counted twice. The bill then moves one period on from its due date. An expense can only be linked to one bill
- Skip a payment, pause or resume, delete (recorded payments stay as ordinary expenses)
- Monthly and yearly bills due on the last day of a month stay on the last day (Jan 31 → Feb 29 → Mar 31)
- Monthly budgets, overall or per expense category, in any supported currency; at most one active budget per category and currency
- Budget progress uses the same rules as every other total: expenses minus refunds, in the budget's currency only; transfers, card repayments and unpaid bills never count. 80% used is shown as near the limit
- Budgets screen with month navigation; dashboard shows budget progress and upcoming bills with their status

## Tests (114, all passing in CI run #9)

| File | Count | Covers |
|---|---|---|
| `FinanceCalculationTests.swift` | 14 | Totals, transfers, refunds, month boundaries, leap year, time zones, card double counting, currencies, rounding |
| `TransactionTests.swift` | 20 (+ parameterized cases) | Draft validation, edit and duplicate rules, amount parsing, filters, repayment detector |
| `RepositoryTests.swift` | 9 | SwiftData add, edit, delete and duplicate; category reassignment; payment-method rules; card double counting end to end |
| `ReportCalculationTests.swift` | 14 | Breakdowns, daily series (leap year, DST), monthly flows, month-over-month, ranges |
| `PersistenceTests.swift` | 3 | First-launch setup, save and reload, default settings |
| `ReceiptParserTests.swift` | 18 (+ parameterized cases) | Synthetic receipts: standard, cash and change, split columns, discounts, grand total and tip, fallbacks, number formats, dates, merchants, currency |
| `ReceiptServicesTests.swift` | 12 | OCR line assembly; **real Vision OCR on a rendered synthetic receipt**; fingerprints; duplicate detection; category suggestions |
| `BillBudgetTests.swift` | 16 | Due status, next due dates (month ends, leap years, custom intervals), bill validation, payment candidates, budget progress and thresholds; SwiftData: recording or linking a payment creates exactly one expense, failed links don't advance the bill, deleting a bill keeps payments, budget rules |
| `ReceiptStorageTests.swift` | 8 | File save, load and delete; path-traversal rejection; orphan cleanup; linking receipts to new or existing transactions; failed saves write nothing; receipts aren't counted as spending |

Xcode counts parameterized cases separately, which is why the total is 114. All tests use synthetic data only.

## Known issues and risks

- The app hasn't been run on a physical iPhone yet. Camera capture can only be tested on a device.
- The UI hasn't been reviewed by eye: chart layout, the largest Dynamic Type sizes, VoiceOver flow and dark mode.
- Receipt parsing is rule-based. Unusual layouts will need manual correction, which the review screen supports.
- Deleting a transaction keeps its receipt record and image. A cleanup option is planned for Phase 6.
- Swift 5 language mode with complete strict-concurrency checking. Warnings should be cleared before moving to Swift 6 mode.
- Bills have no reminder notifications yet; due status shows in the app only.
- A monthly bill on the 30th that passes through February moves to the 29th (or 28th) and stays there; only bills on the last day of a month are kept at month end.
- Bundle ID `com.example.mymoneyai` must be changed to something unique to you when re-signing.

## Building

- **CI:** every push to `main` builds, runs the tests and produces the unsigned IPA.
- **Mac (optional):** Xcode 16+, `brew install xcodegen`, `xcodegen generate`, then build and test the `MyMoneyAI` scheme.

## Next tasks

1. Re-sign the IPA with a free Apple Account and do a manual test pass on an iPhone, including airplane mode and the camera.
2. Phase 6: app lock, encrypted export/import, delete all data, accessibility audit.
