# MyMoney AI

An offline, private iPhone app for tracking income, expenses, receipts and bills.
It is built with SwiftUI, SwiftData, Swift Charts and Apple Vision, targets iOS 17+, and uses no third-party packages, accounts or network access.

> **Build status:** GitHub Actions compiles the app and runs 114 tests on every push (all passing). An unsigned IPA is produced for re-signing.
> See [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md) for what has been verified and what hasn't.

## Repository layout

```
MyMoneyAI/                ← repository root
├── project.yml           ← XcodeGen spec (source of truth for the Xcode project)
├── MyMoneyAI/            ← app sources (this is the source folder, not a nested project)
│   ├── App/  Models/  Features/  Services/  Components/  Utilities/  Resources/
│   └── Tests/            ← unit tests (Swift Testing + XCTest), synthetic data only
├── tools/check_sources.py← static checks that run on Windows
└── docs/                 ← ARCHITECTURE, ROADMAP, BUILD_STATUS
```

The `.xcodeproj` is generated on the Mac and is not committed.

## Developing on Windows

Windows can't compile or run iOS apps. On Windows you can:

1. Edit Swift sources in any editor. VS Code with the Swift extension gives syntax highlighting.
2. Run the static checks with Python 3. They catch unbalanced brackets, duplicate type names and test files that are missing an import:
   ```bash
   python tools/check_sources.py
   ```
3. Commit and push with Git.

These checks are **not** compilation. Type errors, API misuse and test failures only show up on a Mac.

## Building on a Mac

Requirements: macOS with **Xcode 16 or later** (iOS 17+ SDK, Swift Testing) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
XcodeGen is a build-time tool only; the app has no dependencies.

```bash
brew install xcodegen
```

```bash
git clone https://github.com/aravindmarri/MyMoneyAI.git && cd MyMoneyAI
```

```bash
xcodegen generate
```

```bash
xcodebuild -project MyMoneyAI.xcodeproj -scheme MyMoneyAI -destination 'platform=iOS Simulator,name=iPhone 16' build test
```

To run on an iPhone, open `MyMoneyAI.xcodeproj` in Xcode, set your Team under *Signing & Capabilities* for the MyMoneyAI target, choose your device, and run.

After the first Mac build, record the results in `docs/BUILD_STATUS.md`.

## Privacy

- Everything stays on the device. The app has no iCloud sync, analytics, ads or accounts, and never connects to your bank.
- Never commit screenshots of real finances, real receipts, local databases, exports, signing keys or credentials. `.gitignore` blocks common cases, but always review `git status` before committing.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Build status](docs/BUILD_STATUS.md)
