# Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1. Foundation | XcodeGen project, SwiftData schema V1, five-tab navigation, empty states, month summary | Source written, **not compiled** |
| 2. Manual transactions | Add, edit, delete, duplicate; search and filters; category and payment-method management; double-count protection | Source written, **not compiled** |
| 3. Dashboard & reports | Category and payment-method breakdowns, monthly income vs expense, daily trend, month-over-month, year-to-date, custom ranges, Swift Charts with accessible text alternatives | Source written, **not compiled** |
| 4. Receipt import & OCR | PhotosPicker and camera, Vision OCR, deterministic parser with confidence levels, review screen, image storage, duplicate detection, category suggestions | Not started |
| 5. Bills & budgets | Bill editor, due status, mark paid (creates or links one transaction), budget progress | Not started |
| 6. Privacy & quality | Face ID / passcode lock, privacy screen, encrypted export/import (PBKDF2 + AES-GCM), delete all data, accessibility audit, offline verification | Not started |

**Gate:** Phases 1–2 must compile and pass their tests on a Mac before Phase 3 work is treated as building on a verified base.
