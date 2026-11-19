import Foundation

enum CSVError: Error, Equatable, LocalizedError {
    case empty
    case tooLarge
    case tooManyRows
    case unreadableEncoding
    case unterminatedQuote(line: Int)

    var errorDescription: String? {
        switch self {
        case .empty: "The file has no rows."
        case .tooLarge: "The file is too large. Split it into files under \(CSVParser.maximumFileBytes / 1_048_576) MB."
        case .tooManyRows: "The file has more than \(CSVParser.maximumRows) rows. Split it into smaller files."
        case .unreadableEncoding: "The file isn't readable text. Export it from your bank as CSV (UTF-8)."
        case .unterminatedQuote(let line): "Row \(line) has a quote that is never closed, so the file can't be read reliably."
        }
    }
}

/// A parsed CSV file: rows of fields. `lineNumbers[i]` is the 1-based line where row i starts.
struct CSVTable: Equatable, Sendable {
    var rows: [[String]]
    var lineNumbers: [Int]
    var delimiter: Character
}

/// RFC 4180 reader: quoted fields, doubled quotes, embedded newlines, CRLF/LF/CR, UTF-8 BOM.
/// The delimiter (comma, semicolon or tab) is detected from the first line, outside quotes.
enum CSVParser {
    static let maximumFileBytes = 10 * 1_048_576
    static let maximumRows = 50_000
    static let delimiters: [Character] = [",", ";", "\t"]

    static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumFileBytes else { throw CSVError.tooLarge }
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        // Many banks still export Windows-1252.
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        throw CSVError.unreadableEncoding
    }

    static func parse(_ input: String) throws -> CSVTable {
        var text = Substring(input)
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        let delimiter = detectDelimiter(text)

        var rows: [[String]] = []
        var lineNumbers: [Int] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var rowStartLine = 1
        var quoteStartLine = 1
        var chars = text.makeIterator()
        var pending: Character? = nil

        func endRow() throws {
            row.append(field)
            field = ""
            if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) {
                guard rows.count < maximumRows else { throw CSVError.tooManyRows }
                rows.append(row)
                lineNumbers.append(rowStartLine)
            }
            row = []
        }

        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    let next = chars.next()
                    if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                } else {
                    // Swift treats "\r\n" as one Character.
                    if c == "\n" || c == "\r\n" || c == "\r" { line += 1 }
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty:
                inQuotes = true
                quoteStartLine = line
            case delimiter:
                row.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                try endRow()
                line += 1
                rowStartLine = line
            default:
                field.append(c)
            }
        }
        if inQuotes { throw CSVError.unterminatedQuote(line: quoteStartLine) }
        if !field.isEmpty || !row.isEmpty { try endRow() }
        guard !rows.isEmpty else { throw CSVError.empty }
        return CSVTable(rows: rows, lineNumbers: lineNumbers, delimiter: delimiter)
    }

    /// The delimiter that appears most often in the first line, ignoring quoted text. Comma on a tie.
    static func detectDelimiter(_ text: Substring) -> Character {
        var counts: [Character: Int] = [:]
        var inQuotes = false
        for c in text {
            if c == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if c == "\n" || c == "\r\n" || c == "\r" { break }
            if delimiters.contains(c) { counts[c, default: 0] += 1 }
        }
        var best: Character = ","
        for d in delimiters where (counts[d] ?? 0) > (counts[best] ?? 0) { best = d }
        return best
    }
}

/// Writes RFC 4180 CSV with CRLF line endings.
enum CSVWriter {
    /// Text cells that a spreadsheet would run as a formula are prefixed with an apostrophe.
    static func textCell(_ s: String) -> String {
        guard let first = s.first, "=+-@\t\r".contains(first) else { return s }
        return "'" + s
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" || $0 == ";" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func write(_ rows: [[String]]) -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
