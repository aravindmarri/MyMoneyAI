# Build Status

_Last updated: 2026-11-15 (Windows development machine, no Xcode)_

## Summary

| Check | Result |
|---|---|
| iOS compile (Xcode) | **Not run.** No Mac is available. |
| Unit tests (Xcode) | **Not run.** |
| Simulator / device run | **Not run.** |
| Offline (airplane mode) test | **Not run.** The code has no network calls, but this is untested on a device. |
| Static source checks (`python tools/check_sources.py`) | **Pass:** 41 Swift files, balanced brackets, no duplicate types. |

Static checks are not compilation. Expect some compiler errors on the first Mac build.

## Implemented features (source written, not yet compiled)

**Phase 1**
- XcodeGen project (iOS 17, iPhone, portrait) with app and unit-test targets
- SwiftData schema V1 and migration plan, CloudKit disabled, store protected with iOS Data Protection
- First-launch setup creates only the default categories and settings, with no sample transactions
- Five tabs: Home, Transactions, Scan, Reports, Settings, each with an empty state
- Home: month navigation, income, expenses, net cash flow, spent-of-income ratio, recent transactions, upcoming bills
- Reports: year-to-date summary
- Settings: currency and appearance preferences, privacy page

**Phase 2**
- Add, edit and delete transactions (delete asks for confirmation); duplicate opens an unsaved copy
- Search by title or merchant; filter by type, category, payment method and date range
- Transfers record both the source and destination accounts
- Credit-card repayment protection: the editor warns when an expense looks like a card payment and offers to record it as a Transfer
- Category management: create and edit (name, icon, color); deleting a category in use requires moving its transactions
- Payment-method management: create and edit; Apple Pay can link to a card; only the last four digits are stored; methods with history can be deactivated but not deleted
- Amount entry accepts "12.50", "1,234.56", "1.234,56" and "12,5"

**Phase 3**
- Dashboard: spending-by-category donut and a 6-month income vs expenses chart for the selected month
- Reports: period picker (this month, last month, last 3 or 6 months, year to date, custom dates)
- Reports: income vs expenses by month, spending by category, spending by payment method, top merchants, daily spending trend
- Reports: this month vs last month comparison and a year-to-date summary
- Charts: accessibility labels on every mark plus a "Show data" text table; tap a month on the cash-flow chart to see its net
- Chart values use `Double` for drawing only; all calculations stay in integer minor units

## Tests written (60 functions; none executed yet)

| File | Covers |
|---|---|
| `FinanceCalculationTests.swift` (14) | Income, expense and net totals; transfers and adjustments excluded; refunds and income reversals; month boundaries; leap year; time zones; transaction date vs record date; card purchase and repayment across months; excluded currencies; rounding; last-four sanitizing |
| `TransactionTests.swift` (20) | Draft validation; editing keeps the id and creation date; duplicating drops receipt and bill links; transfer field clearing; amount parsing; filters; repayment detector |
| `RepositoryTests.swift` (9) | SwiftData add, edit, delete and duplicate; category reassignment rules; budget deactivation; in-use payment methods; end-to-end card-repayment double-count check |
| `ReportCalculationTests.swift` (14) | Category, payment-method and merchant breakdowns net of refunds; breakdowns match summary totals; transfers, income and other currencies excluded; daily series including leap year and DST; monthly flows across year boundaries and clipped ranges; month-over-month change; year-to-date and custom ranges; report presets |
| `PersistenceTests.swift` (3) | First-launch setup runs only once and adds no sample data; save and reload; default settings |

## Tests not executable on Windows

All of them. They need Xcode (Swift Testing, XCTest and SwiftData on the iOS Simulator).

## Known issues and risks

- None of the code has been compiled. API mismatches or type-checker timeouts are likely in the larger SwiftUI views.
- Swift 5 language mode is used with `SWIFT_STRICT_CONCURRENCY=complete`. Concurrency diagnostics show up as warnings and should be fixed before moving to Swift 6 mode.
- The views use `@Query` with in-memory filtering. That's fine for V1 data sizes but should be profiled with more than 10,000 transactions.
- Deleting a transaction keeps its receipt record. Receipt file cleanup is planned for Phase 4.
- Swift Charts layout (legend sizing, annotation clipping) is untested visually.
- Scan, Bills and Budgets screens are read-only placeholders until Phases 4–5. The Scan screen says import isn't available yet.
- The development team and bundle ID (`com.example.mymoneyai`) must be set before installing on a device.

## Mac build requirements

- macOS with Xcode 16 or later, iOS 17+ simulator runtime
- XcodeGen (`brew install xcodegen`)
- `xcodegen generate`, then build and test the `MyMoneyAI` scheme (see README)

## Next tasks

1. **On a Mac:** generate the project, fix any compile errors, run all tests, and record the results here.
2. Check the charts on a device: Dynamic Type at the largest sizes, VoiceOver, dark mode.
3. Phase 4: receipt import and OCR.
