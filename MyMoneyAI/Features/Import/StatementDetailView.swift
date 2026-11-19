import SwiftUI
import SwiftData

/// A saved statement: progress, the suggestion for every line, bulk confirmation, duplicates,
/// transactions missing from the statement, and undo for the whole import.
struct StatementDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let statementId: UUID

    @Query private var statements: [ImportedStatement]
    @Query private var lines: [StatementTransaction]
    @Query private var matches: [ReconciliationMatch]
    @Query private var transactions: [MoneyTransaction]
    @Query private var accounts: [FinancialAccount]
    @AppStorage(ReconciliationPreferences.windowKey) private var windowDays = MatchDateWindow.twoDays.rawValue
    @State private var filter: LineFilter = .all
    @State private var confirmDelete = false
    @State private var message: String?
    @State private var reviewing: ReviewRoute?
    @State private var showBulk = false
    @State private var duplicates: [UUID: StatementTransaction] = [:]
    @State private var identicalGroups: [[UUID]] = []
    @State private var missing: [TransactionRecord] = []

    struct ReviewRoute: Identifiable { let id: UUID }

    enum LineFilter: String, CaseIterable, Identifiable {
        case all, open, strong, possible, weak, choose, noMatch, done
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .open: "To review"
            case .done: "Done"
            case .strong: "Strong"
            case .possible: "Possible"
            case .weak: "Weak"
            case .choose: "Choose"
            case .noMatch: "No match"
            }
        }
    }

    init(statementId: UUID) {
        self.statementId = statementId
        _statements = Query(filter: #Predicate<ImportedStatement> { $0.id == statementId })
        _lines = Query(filter: #Predicate<StatementTransaction> { $0.statementId == statementId },
                       sort: [SortDescriptor(\StatementTransaction.sourcePage), SortDescriptor(\StatementTransaction.sourceLine)])
    }

    private var statement: ImportedStatement? { statements.first }
    private var lineIds: Set<UUID> { Set(lines.map(\.id)) }
    private var statementMatches: [ReconciliationMatch] { matches.filter { lineIds.contains($0.statementTransactionId) } }
    private func primary(_ line: StatementTransaction) -> ReconciliationMatch? {
        statementMatches.first { $0.statementTransactionId == line.id && $0.isPrimary && $0.status == .suggested }
    }
    private func alternatives(_ line: StatementTransaction) -> [ReconciliationMatch] {
        statementMatches.filter { $0.statementTransactionId == line.id && !$0.isPrimary && $0.status == .suggested }
            .sorted { $0.score > $1.score }
    }
    private var transactionsById: [UUID: MoneyTransaction] { Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    private func passes(_ line: StatementTransaction) -> Bool {
        let p = primary(line)
        let resolved = line.status == .matched || line.status == .created || line.status == .skipped
        switch filter {
        case .all: return true
        case .open: return !resolved
        case .done: return resolved
        case .strong: return p?.strength == .strong && p?.isAmbiguous == false
        case .possible: return p?.strength == .possible
        case .weak: return p?.strength == .weak
        case .choose: return p?.isAmbiguous == true
        case .noMatch: return p == nil && !resolved
        }
    }

    var body: some View {
        if let statement {
            List {
                progressSection(statement)
                summarySection(statement)
                matchingSection
                if !duplicates.isEmpty || !identicalGroups.isEmpty { duplicatesSection }
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(LineFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    let byId = transactionsById
                    ForEach(lines.filter(passes)) { line in
                        Button { reviewing = ReviewRoute(id: line.id) } label: {
                            StatementMatchRow(line: line, match: primary(line), alternatives: alternatives(line), transactionsById: byId)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Lines (\(lines.count))")
                } footer: {
                    Text("Tap a line to confirm, reject, add or skip it. Nothing changes in your transactions until you do.")
                }
                if !missing.isEmpty { missingSection(statement) }
                Section {
                    Button("Undo This Import", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Removes the statement, releases every confirmed match, restores any amount you changed, and deletes transactions that were added from this statement. Nothing else is touched.")
                }
            }
            .navigationTitle(statement.institutionName ?? statement.originalFilename)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Undo this import?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Undo Import", role: .destructive) { deleteImport() }
            } message: {
                let added = lines.filter { $0.status == .created }.count
                Text(added > 0 ? "\(added) transaction(s) added from this statement will be deleted. Confirmed matches are released; your other transactions stay as they are."
                               : "The statement and its suggestions are removed. Your transactions stay as they are.")
            }
            .sheet(item: $reviewing, onDismiss: loadChecks) { route in StatementLineReviewView(lineId: route.id) }
            .sheet(isPresented: $showBulk, onDismiss: loadChecks) { BulkConfirmView(statementId: statementId) }
            .task { loadChecks() }
            .alert("Statement", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        } else {
            ContentUnavailableView("Statement Not Found", systemImage: "doc.questionmark")
        }
    }

    private func progressSection(_ s: ImportedStatement) -> some View {
        let done = lines.filter { $0.status == .matched || $0.status == .created || $0.status == .skipped }.count
        let bulk = (try? app.statements.bulkConfirmCandidates(statementId: statementId).count) ?? 0
        return Section {
            ProgressView(value: lines.isEmpty ? 0 : Double(done) / Double(lines.count)) {
                Text("\(done) of \(lines.count) lines reviewed")
            }
            LabeledContent("Confirmed", value: "\(lines.filter { $0.status == .matched }.count)")
            LabeledContent("Added as new", value: "\(lines.filter { $0.status == .created }.count)")
            LabeledContent("Skipped", value: "\(lines.filter { $0.status == .skipped }.count)")
            if bulk > 0 {
                Button { showBulk = true } label: { Label("Confirm \(bulk) Strong Matches…", systemImage: "checkmark.seal") }
            }
            switch s.reconciliationStatus {
            case .reconciled:
                Label("Every line is reviewed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .incomplete:
                Label("Every read line is reviewed, but \(s.unreadLineCount) line(s) couldn't be read from the file", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            default:
                EmptyView()
            }
        } header: {
            Text("Review")
        } footer: {
            Text("Balance checks against the statement totals come in the next update, so a reviewed statement isn't yet a proven balance.")
        }
    }

    private var duplicatesSection: some View {
        Section {
            ForEach(Array(duplicates.keys), id: \.self) { id in
                if let line = lines.first(where: { $0.id == id }), line.status == .unmatched || line.status == .suggested {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.originalDescription).lineLimit(1)
                        Text("Already on an earlier statement for this account (overlapping periods).").font(.caption).foregroundStyle(.orange)
                        Button("Skip as Duplicate") {
                            do { try app.statements.skip(lineId: id); loadChecks() } catch { message = error.localizedDescription }
                        }
                        .font(.caption)
                    }
                }
            }
            ForEach(identicalGroups, id: \.self) { group in
                if let first = lines.first(where: { $0.id == group[0] }) {
                    Text("\(group.count) identical lines: \(first.originalDescription), \(CurrencyMath.format(first.amountMinorUnits, currencyCode: first.currencyCode)). They are kept as separate purchases; skip one only if it is a real duplicate.")
                        .font(.caption)
                }
            }
        } header: {
            Text("Possible duplicates")
        }
    }

    private func missingSection(_ s: ImportedStatement) -> some View {
        Section {
            ForEach(missing, id: \.id) { t in
                HStack {
                    VStack(alignment: .leading) {
                        Text(t.merchant ?? t.title)
                        Text(t.transactionDate.formatted(date: .abbreviated, time: .omitted) + " · " + t.transactionType.displayName)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(CurrencyMath.format(t.amountMinorUnits, currencyCode: t.currencyCode)).monospacedDigit()
                }
            }
        } header: {
            Text("In the app but not on this statement (\(missing.count))")
        } footer: {
            Text("Recorded on this account during the statement period but not found on it. Check the date or payment method, or whether it was a duplicate. The last 3 days of the period are left out because those may post on the next statement.")
        }
    }

    private func loadChecks() {
        duplicates = (try? app.statements.overlappingDuplicates(statementId: statementId)) ?? [:]
        identicalGroups = (try? app.statements.identicalLineGroups(statementId: statementId)) ?? []
        missing = (try? app.statements.appTransactionsMissingFromStatement(statementId: statementId)) ?? []
    }

    private func summarySection(_ s: ImportedStatement) -> some View {
        let account = accounts.first { $0.id == s.accountId }
        let primaries = lines.compactMap(primary)
        let strong = primaries.filter { $0.strength == .strong && !$0.isAmbiguous }.count
        let possible = primaries.filter { $0.strength == .possible }.count
        let weak = primaries.filter { $0.strength == .weak }.count
        let ambiguous = primaries.filter(\.isAmbiguous).count
        let none = lines.filter { primary($0) == nil }.count
        return Section {
            LabeledContent("Account", value: account.map { "\($0.nickname) · \($0.accountType.displayName)" } ?? "—")
            LabeledContent("Type", value: s.documentKind.displayName)
            if let start = s.periodStart, let end = s.periodEnd {
                LabeledContent("Period", value: "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
            }
            if let closing = s.closingBalance {
                LabeledContent(s.documentKind == .creditCardStatement ? "New balance" : "Closing balance",
                               value: CurrencyMath.format(closing, currencyCode: s.currencyCode))
            }
            LabeledContent("Strong matches", value: "\(strong)")
            LabeledContent("Possible matches", value: "\(possible)")
            LabeledContent("Weak matches", value: "\(weak)")
            if ambiguous > 0 { LabeledContent("Need you to choose", value: "\(ambiguous)") }
            LabeledContent("No match in the app", value: "\(none)")
            if s.unreadLineCount > 0 { LabeledContent("Lines that couldn't be read", value: "\(s.unreadLineCount)") }
        } header: {
            Text("Summary")
        } footer: {
            Text("Imported \(s.importedAt.formatted(date: .abbreviated, time: .shortened)) from “\(s.originalFilename)”.")
        }
    }

    private var matchingSection: some View {
        Section {
            Picker("Date window", selection: $windowDays) {
                ForEach(MatchDateWindow.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Button("Find Matches Again") { refresh() }
        } header: {
            Text("Matching")
        } footer: {
            Text("How far apart a statement date and your transaction's date may be. Banks often post card purchases a day or two later. Matches found outside the window are shown with lower confidence.")
        }
    }

    private func refresh() {
        do {
            try app.statements.refreshSuggestions(statementId: statementId, config: ReconciliationPreferences.config())
            message = "Suggestions updated."
        } catch { message = error.localizedDescription }
    }

    private func deleteImport() {
        do {
            try app.statements.rollbackImport(statementId: statementId)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

/// One statement line next to the transaction suggested for it, with the reasons.
struct StatementMatchRow: View {
    let line: StatementTransaction
    let match: ReconciliationMatch?
    let alternatives: [ReconciliationMatch]
    let transactionsById: [UUID: MoneyTransaction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.originalDescription).lineLimit(2)
                    Text(line.transactionDate.formatted(date: .abbreviated, time: .omitted) + " · " + line.kind.displayName
                         + (line.isPending ? " · Pending" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text((line.direction == .moneyIn ? "+" : "−") + CurrencyMath.format(line.amountMinorUnits, currencyCode: line.currencyCode))
                    .monospacedDigit()
            }
            if line.status == .matched || line.status == .created || line.status == .skipped {
                let t = line.matchedTransactionId.flatMap { transactionsById[$0] }
                let name = t.map { $0.merchant ?? $0.title } ?? ""
                Label(line.status == .matched ? "Confirmed: \(name)" : (line.status == .created ? "Added: \(name)" : "Skipped"),
                      systemImage: line.status == .skipped ? "forward.fill" : "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(line.status == .skipped ? Color.secondary : Color.green)
            } else if let match, let t = transactionsById[match.transactionId] {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(match.isAmbiguous ? "Choose: several close matches" : match.strength.displayName, systemImage: symbol(match))
                            .font(.caption.weight(.semibold)).foregroundStyle(color(match))
                        Spacer()
                        Text("\(match.score)/100").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("In the app: \(t.merchant ?? t.title)").font(.subheadline).lineLimit(1)
                        Spacer()
                        Text(CurrencyMath.format(t.amountMinorUnits, currencyCode: t.currencyCode)).font(.subheadline.monospacedDigit())
                            .foregroundStyle(match.amountDifferenceMinorUnits == 0 ? Color.primary : Color.orange)
                    }
                    Text(t.transactionDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(match.dateDifferenceDays == 0 ? Color.secondary : Color.orange)
                    DisclosureGroup("Why") {
                        ForEach(match.reasons, id: \.self) { Text("• " + $0).font(.caption) }
                        if !alternatives.isEmpty {
                            Text("Other candidates: " + alternatives.compactMap { a in
                                transactionsById[a.transactionId].map { "\($0.merchant ?? $0.title) (\(a.score))" }
                            }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Label("Not in the app yet", systemImage: "plus.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func symbol(_ m: ReconciliationMatch) -> String {
        if m.isAmbiguous { return "questionmark.circle.fill" }
        switch m.strength {
        case .strong: return "checkmark.seal.fill"
        case .possible: return "checkmark.circle"
        case .weak: return "circle.dotted"
        }
    }

    private func color(_ m: ReconciliationMatch) -> Color {
        if m.isAmbiguous { return .orange }
        switch m.strength {
        case .strong: return .green
        case .possible: return .blue
        case .weak: return .secondary
        }
    }
}

/// Saved statements, newest first.
struct SavedStatementsSection: View {
    @Query(sort: \ImportedStatement.importedAt, order: .reverse) private var statements: [ImportedStatement]

    var body: some View {
        if !statements.isEmpty {
            Section("Saved Statements") {
                ForEach(statements.prefix(20)) { s in
                    NavigationLink {
                        StatementDetailView(statementId: s.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.institutionName ?? s.originalFilename).lineLimit(1)
                            Text([s.documentKind.displayName,
                                  s.periodEnd.map { "to " + $0.formatted(date: .abbreviated, time: .omitted) },
                                  "imported " + s.importedAt.formatted(date: .abbreviated, time: .omitted)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
