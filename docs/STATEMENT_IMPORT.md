# Statement import and reconciliation

Goal: import bank and credit-card statements on the iPhone, check them against the transactions already
in the app, find what's missing, stop duplicates, and reconcile, all offline.

This document is the plan and the reference for how import and matching behave. Sections are
marked **Done** as each phase passes CI.

## What already exists and is reused

| Existing piece | Reused for |
|---|---|
| `VisionReceiptOCRService` (Apple Vision, on-device) and `OCRLineAssembler` | OCR of scanned PDF pages |
| `CSVParser`, `CSVImportSource`, `CSVColumnMapping`, `CSVTransactionImporter` (Phase 7) | CSV statements, column mapping, row errors |
| `CSVAmountParser`, `CSVDateParser` | Amounts (signs, brackets, CR/DR) and dates in PDF and TXT statements |
| `MerchantName.normalize`, `HeuristicCategorySuggestionService` | Merchant normalization and category suggestions |
| `PaymentMethod` (cash, debit, credit, bank) | The account a statement belongs to (becomes `FinancialAccount` in Phase B) |
| `TransactionType.transfer` + `CreditCardRepaymentDetector` | Card repayments and own-account transfers are never counted as spending |
| `BackupService`, schema versioning (V1 → V2 migration in place) | New models are added as schema V3 with a tested migration |

## Phases

### Phase A: import, recognition, extraction, preview (**Done**: CI run #22)
- Import Center on the Import tab: statements (PDF, CSV, TXT, several at once), receipts and screenshots.
- `DocumentFormatDetector`: PDF, CSV, TXT, image; XLSX, OFX and QFX are recognised and reported as "not supported yet"
  through the same `DocumentReading` interface, so readers can be added later without changing the flow.
- `PDFStatementReader` (PDFKit): text per page in reading order; pages with no text are rendered one at a time and read
  with Vision OCR. Password-protected PDFs ask for the password, which is used in memory only and never stored or logged.
- `DocumentClassifier`: suggests bank statement, credit-card statement, receipt, invoice, payment confirmation,
  transaction export or unknown, with the reasons. The user confirms the type.
- `StatementHeaderExtractor`: institution, account type, last four digits only (a full number is cut to its last four),
  statement period, opening and closing balance, deposits, withdrawals, payments and credits, purchases, fees, interest,
  due date, minimum payment, currency. Every field is editable.
- `StatementLineParser`: transaction lines with one or two dates (transaction and posting), wrapped descriptions,
  running balances, section headings (deposits, withdrawals, payments, purchases, fees, interest), CR/DR and negative
  amounts, year inference across December–January, pending rows. Lines that look like transactions but can't be read are
  kept as parse issues with page and line, never dropped, and can be corrected by hand.
- CSV: balance and status (pending/posted) columns; confirmed mappings are remembered per file layout.
- SHA-256 fingerprint of every file (used for duplicate-document detection in Phase B).
- Nothing is saved to the database in Phase A. Source files are read into memory from the security-scoped URL and not copied.

### Phase B: models, migration, matching (**Done**: CI run #28)
- Schema V3: `FinancialAccount` (mapped from payment methods), `ImportSession`, `ImportedStatement`,
  `StatementTransaction`, `ReconciliationMatch`, `MerchantAlias`. Lightweight migration, tested on a real V2 store.
- `StatementReconciliationService`: hard constraints (currency, direction), then an explainable score: amount 45%,
  merchant 25%, date 15%, account 15% (configurable). Date window ±2 calendar days by default (exact, ±1, ±2, ±3, ±7);
  wider windows lower confidence and say why. Strong / possible / weak / no match. Ties show every candidate.
  One existing transaction can back only one statement line. Posting dates never overwrite purchase dates.

### Phase C: review, duplicates, transfers (**Done**: CI run #30)
- Side-by-side match review; confirm, reject, pick another, create new, mark transfer or card repayment, skip, later.
- Bulk confirm for strong, unambiguous matches after a preview. All-or-nothing saves; undo of a whole import.
- Duplicate document (fingerprint + account + period), duplicate transaction, potential duplicate, and legitimate
  identical purchases are told apart.
- Transfer pairing across accounts (card payment out of checking ↔ payment credit on the card): one transfer, never an
  expense. Interest and fees are expenses. Cash withdrawals are transfers to Cash when cash is tracked.

### Phase D: balance validation and dashboards
- Bank: opening + deposits − withdrawals = closing. Card: previous + purchases + fees + interest − payments − credits =
  new balance. Differences and coverage are shown; a statement is never called reconciled when data is missing.
- Spending by account, card spending, bank cash flow, verified vs unverified, monthly coverage, open discrepancies.

### Phase E: optional on-device AI, hardening
- Apple Foundation Models (availability-gated, optional) for unusual descriptions, merchant names and explanations only.
  Never for totals or for changing records. Full deterministic fallback.
- Performance on long statements, privacy review, backup of the new models, more fixtures.

## Rules that every phase keeps
- Offline only. No bank connections, credentials, cloud OCR or cloud AI.
- Amounts are `Int64` minor units; matching and totals are deterministic.
- Nothing is saved without the user's approval; nothing is silently dropped or overwritten.
- No real statements in the repository. Test fixtures are generated in code with made-up data.
