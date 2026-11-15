# Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1. Foundation | XcodeGen project, SwiftData schema V1, five-tab navigation, empty states, month summary | **Done:** CI build and tests passing |
| 2. Manual transactions | Add, edit, delete, duplicate; search and filters; category and payment-method management; double-count protection | **Done:** CI build and tests passing |
| 3. Dashboard & reports | Category and payment-method breakdowns, monthly income vs expense, daily trend, month-over-month, year-to-date, custom ranges, Swift Charts with accessible text alternatives | **Done:** CI build and tests passing |
| 4. Receipt import & OCR | PhotosPicker and camera, Vision OCR, deterministic parser with confidence levels, review screen, image storage, duplicate detection, category suggestions | **Done:** CI build and tests passing |
| 5. Bills & budgets | Bill editor, due status, mark paid (creates or links one transaction), budget progress | **Done:** CI build and tests passing |
| 6. Privacy & quality | Face ID / passcode lock, privacy screen, encrypted export/import (PBKDF2 + AES-GCM), delete all data, accessibility audit, offline verification | **Done:** CI build and tests passing (on-device check pending) |

| 7. CSV import & export | Bank statement import with column mapping, preview and duplicate skipping; transaction export for spreadsheets | **Done:** CI build and tests passing |

**Status:** Phases 1–7 compile and pass 153 automated tests on GitHub Actions (run #16). Manual on-device testing is still pending.
