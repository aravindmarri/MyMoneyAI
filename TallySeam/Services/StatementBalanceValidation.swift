import Foundation

/// Everything the balance checks need, decoupled from SwiftData. Amounts are minor units; header
/// totals may be printed with either sign, so their magnitude is used.
struct StatementBalanceInput: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var amountMinorUnits: Int64
        var direction: StatementDirection
        var runningBalance: Int64?
        var page: Int
        var line: Int
        var isPending: Bool
    }

    var isCreditCard: Bool
    var currencyCode: String
    var openingBalance: Int64?
    var closingBalance: Int64?
    var totalDeposits: Int64?
    var totalWithdrawals: Int64?
    var totalPaymentsAndCredits: Int64?
    var totalPurchases: Int64?
    var totalFees: Int64?
    var totalInterest: Int64?
    var lines: [Line]
    var unreadLineCount: Int
}

enum BalanceCheckResult: Equatable, Sendable {
    case balanced
    /// Expected minus what the statement shows.
    case difference(Int64)
    case notAvailable(String)

    var isBalanced: Bool { self == .balanced }
    var isDifference: Bool { if case .difference = self { true } else { false } }
}

struct BalanceCheck: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var result: BalanceCheckResult
    var expected: Int64?
    var actual: Int64?
    /// What a difference probably means.
    var hint: String?
}

/// A running balance that doesn't follow from the previous one: a row is probably missing above
/// it, or an amount was misread.
struct RunningBalanceBreak: Equatable, Sendable {
    var page: Int
    var line: Int
    var expected: Int64
    var printed: Int64
}

enum BalanceVerdict: Equatable, Sendable {
    /// The transactions read add up to the closing balance and nothing contradicts it.
    case verified
    /// At least one check shows a difference.
    case differences
    /// The statement doesn't give enough to prove the balance (for example no opening balance), or
    /// some lines couldn't be read.
    case notEnoughInformation

    var displayName: String {
        switch self {
        case .verified: "Balance verified"
        case .differences: "Differences found"
        case .notEnoughInformation: "Balance not proven"
        }
    }
}

struct StatementBalanceReport: Equatable, Sendable {
    var checks: [BalanceCheck]
    var runningBalanceBreaks: [RunningBalanceBreak]
    var verdict: BalanceVerdict
    /// Plain-language explanation of the verdict.
    var explanation: String
}

/// Deterministic statement arithmetic.
/// Bank: opening + deposits − withdrawals = closing.
/// Card: previous balance + purchases + fees + interest − payments and credits = new balance.
/// Pending lines are left out of the sums, as statements don't include them in balances.
enum StatementBalanceValidator {
    static func validate(_ s: StatementBalanceInput) -> StatementBalanceReport {
        let posted = s.lines.filter { !$0.isPending }
        let moneyIn = posted.filter { $0.direction == .moneyIn }.reduce(Int64(0)) { $0 + $1.amountMinorUnits }
        let moneyOut = posted.filter { $0.direction == .moneyOut }.reduce(Int64(0)) { $0 + $1.amountMinorUnits }
        var checks: [BalanceCheck] = []

        func compare(_ id: String, _ title: String, expected: Int64?, actual: Int64?, missing: String, hint: String) {
            guard let expected, let actual else {
                checks.append(BalanceCheck(id: id, title: title, result: .notAvailable(missing), expected: expected, actual: actual))
                return
            }
            let diff = expected - actual
            checks.append(BalanceCheck(id: id, title: title, result: diff == 0 ? .balanced : .difference(diff),
                                       expected: expected, actual: actual, hint: diff == 0 ? nil : hint))
        }

        if s.isCreditCard {
            // 1. Read transactions → new balance.
            let fromLines = s.openingBalance.map { $0 + moneyOut - moneyIn }
            compare("lines", "Transactions read add up to the new balance", expected: fromLines, actual: s.closingBalance,
                    missing: "The previous or new balance wasn't found on the statement.",
                    hint: "A transaction may be missing from what was read, or an amount was misread.")
            // 2. The statement's own summary.
            var summary: Int64?
            if let o = s.openingBalance, let p = s.totalPurchases, let c = s.totalPaymentsAndCredits {
                summary = o + abs(p) + abs(s.totalFees ?? 0) + abs(s.totalInterest ?? 0) - abs(c)
            }
            compare("summary", "Statement summary adds up", expected: summary, actual: s.closingBalance,
                    missing: "The summary totals weren't all found.",
                    hint: "A summary figure was probably misread. Check it against the statement.")
            // 3. Totals read vs printed totals.
            let printedCharges = s.totalPurchases.map { abs($0) + abs(s.totalFees ?? 0) + abs(s.totalInterest ?? 0) }
            compare("out", "Charges read match the statement", expected: printedCharges, actual: moneyOut,
                    missing: "The purchases total wasn't found.", hint: "Charges read differ from the printed total.")
            compare("in", "Payments and credits read match the statement", expected: s.totalPaymentsAndCredits.map(abs), actual: moneyIn,
                    missing: "The payments total wasn't found.", hint: "Payments read differ from the printed total.")
        } else {
            let fromLines = s.openingBalance.map { $0 + moneyIn - moneyOut }
            compare("lines", "Transactions read add up to the closing balance", expected: fromLines, actual: s.closingBalance,
                    missing: "The opening or closing balance wasn't found on the statement.",
                    hint: "A transaction may be missing from what was read, or an amount was misread.")
            var summary: Int64?
            if let o = s.openingBalance, let d = s.totalDeposits, let w = s.totalWithdrawals { summary = o + abs(d) - abs(w) }
            compare("summary", "Statement summary adds up", expected: summary, actual: s.closingBalance,
                    missing: "The deposit and withdrawal totals weren't both found.",
                    hint: "A summary figure was probably misread. Check it against the statement.")
            compare("in", "Deposits read match the statement", expected: s.totalDeposits.map(abs), actual: moneyIn,
                    missing: "The deposits total wasn't found.", hint: "Deposits read differ from the printed total.")
            compare("out", "Withdrawals read match the statement", expected: s.totalWithdrawals.map(abs), actual: moneyOut,
                    missing: "The withdrawals total wasn't found.", hint: "Withdrawals read differ from the printed total.")
        }

        let breaks = s.isCreditCard ? [] : runningBalanceBreaks(posted, opening: s.openingBalance)

        let main = checks.first { $0.id == "lines" }?.result
        let verdict: BalanceVerdict
        let explanation: String
        if checks.contains(where: { $0.result.isDifference }) || !breaks.isEmpty {
            verdict = .differences
            explanation = breaks.first.map { "The running balance stops adding up at page \($0.page), line \($0.line). A row may be missing just above it, or an amount was misread." }
                ?? "The figures don't add up. See the checks below for where the difference is."
        } else if s.unreadLineCount > 0 {
            verdict = .notEnoughInformation
            explanation = "\(s.unreadLineCount) line(s) couldn't be read, so the balance can't be proven until they're entered."
        } else if main?.isBalanced == true {
            verdict = .verified
            explanation = "The transactions read add up exactly to the statement's balance."
        } else {
            verdict = .notEnoughInformation
            explanation = "The statement doesn't show enough figures (opening and closing balance) to prove the balance."
        }
        return StatementBalanceReport(checks: checks, runningBalanceBreaks: breaks, verdict: verdict, explanation: explanation)
    }

    /// Walks the lines in order; whenever a line prints a running balance, it must equal the last
    /// known balance plus everything since. Lines without a balance are carried forward.
    static func runningBalanceBreaks(_ lines: [StatementBalanceInput.Line], opening: Int64?) -> [RunningBalanceBreak] {
        var running = opening
        var breaks: [RunningBalanceBreak] = []
        for l in lines.sorted(by: { ($0.page, $0.line) < ($1.page, $1.line) }) {
            let signed = l.direction == .moneyIn ? l.amountMinorUnits : -l.amountMinorUnits
            running = running.map { $0 + signed }
            if let printed = l.runningBalance {
                if let r = running, r != printed { breaks.append(RunningBalanceBreak(page: l.page, line: l.line, expected: r, printed: printed)) }
                running = printed
            }
        }
        return breaks
    }
}

// MARK: - Verified spending

/// How much of a month's spending is backed by a confirmed statement line.
struct SpendingCoverage: Equatable, Sendable {
    var verifiedMinorUnits: Int64
    var unverifiedMinorUnits: Int64
    var verifiedCount: Int
    var unverifiedCount: Int
    var totalMinorUnits: Int64 { verifiedMinorUnits + unverifiedMinorUnits }
    /// 0–100, rounded down so it never overstates coverage.
    var percentVerified: Int {
        guard totalMinorUnits > 0 else { return 0 }
        return Int(max(0, verifiedMinorUnits) * 100 / totalMinorUnits)
    }
}

enum ReconciliationSummaryService {
    /// Uses the same rules as every other total (reporting month, refunds subtract, transfers and
    /// other currencies excluded), split by whether a confirmed statement line backs the expense.
    static func coverage(records: [TransactionRecord], verifiedIds: Set<UUID>, range: DateRange, currencyCode: String,
                         calendar: Calendar) -> SpendingCoverage {
        var c = SpendingCoverage(verifiedMinorUnits: 0, unverifiedMinorUnits: 0, verifiedCount: 0, unverifiedCount: 0)
        for r in records where r.transactionType == .expense && r.currencyCode == currencyCode && range.contains(r.reportingDate(in: calendar)) {
            let v = r.isRefund ? -r.amountMinorUnits : r.amountMinorUnits
            if verifiedIds.contains(r.id) { c.verifiedMinorUnits += v; c.verifiedCount += 1 }
            else { c.unverifiedMinorUnits += v; c.unverifiedCount += 1 }
        }
        return c
    }
}
