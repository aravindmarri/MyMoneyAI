import Foundation
import CryptoKit
import CoreGraphics
import PDFKit
import UniformTypeIdentifiers

// MARK: - Formats

/// File formats the importer recognises. Formats marked unsupported are detected so the user gets a
/// clear message, and a reader can be added later behind `DocumentReading` without changing the flow.
enum DocumentFormat: String, CaseIterable, Sendable {
    case pdf, csv, text, image, xlsx, ofx, qfx, unknown

    var isSupported: Bool {
        switch self {
        case .pdf, .csv, .text, .image: true
        case .xlsx, .ofx, .qfx, .unknown: false
        }
    }

    var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .csv: "CSV"
        case .text: "Text"
        case .image: "Image"
        case .xlsx: "Excel (XLSX)"
        case .ofx: "OFX"
        case .qfx: "Quicken (QFX)"
        case .unknown: "Unknown"
        }
    }

    /// Types offered in the file picker.
    static var importableTypes: [UTType] {
        var types: [UTType] = [.pdf, .commaSeparatedText, .plainText, .text, .image, .spreadsheet]
        for ext in ["ofx", "qfx", "xlsx", "tsv"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
}

enum DocumentFormatDetector {
    /// Detects from the file's first bytes, falling back to its extension.
    static func detect(filename: String, data: Data) -> DocumentFormat {
        let head = [UInt8](data.prefix(8))
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }                       // %PDF
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) || head.starts(with: [0xFF, 0xD8, 0xFF]) { return .image }  // PNG, JPEG
        if head.count >= 8, head[4...7] == [0x66, 0x74, 0x79, 0x70] { return .image }           // HEIC/HEIF ("ftyp")
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "csv", "tsv": return .csv
        case "txt", "text": return .text
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp": return .image
        case "xlsx", "xls": return .xlsx
        case "ofx": return .ofx
        case "qfx": return .qfx
        default: break
        }
        // A text file whose first line has several commas or semicolons is treated as CSV.
        if let text = String(data: data.prefix(4_096), encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("OFXHEADER") || trimmed.contains("<OFX>") { return ext == "qfx" ? .qfx : .ofx }
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            if firstLine.filter({ $0 == "," }).count >= 2 || firstLine.filter({ $0 == ";" }).count >= 2 { return .csv }
            return .text
        }
        return .unknown
    }
}

enum DocumentFingerprint {
    /// Hex SHA-256 of the file's bytes. Identical files always give the same value.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Extracted text

/// Text of one page, in reading order, with where it came from.
struct DocumentPage: Equatable, Sendable {
    enum Source: String, Sendable { case embeddedText, ocr, plainText }
    var index: Int
    var lines: [String]
    var source: Source
}

struct DocumentText: Equatable, Sendable {
    var pages: [DocumentPage]
    var allLines: [String] { pages.flatMap(\.lines) }
    var usedOCR: Bool { pages.contains { $0.source == .ocr } }
}

enum DocumentReadError: Error, Equatable, LocalizedError {
    case unsupportedFormat(DocumentFormat)
    case passwordRequired
    case wrongPassword
    case unreadable
    case tooLarge
    case tooManyPages(Int)
    case noText

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let f): "\(f.displayName) files can't be imported yet. Export the statement as PDF or CSV instead."
        case .passwordRequired: "This PDF is protected with a password."
        case .wrongPassword: "That password didn't open the PDF."
        case .unreadable: "The file couldn't be opened. It may be damaged, or not really a PDF."
        case .tooLarge: "The file is larger than \(DocumentLimits.maximumFileBytes / 1_048_576) MB."
        case .tooManyPages(let n): "The PDF has \(n) pages; the limit is \(DocumentLimits.maximumPages). Split it into smaller files."
        case .noText: "No text was found in the document."
        }
    }
}

enum DocumentLimits {
    static let maximumFileBytes = 50 * 1_048_576
    static let maximumPages = 300
    /// A page with fewer characters than this is treated as scanned and read with OCR.
    static let minimumEmbeddedCharacters = 20
}

/// Reads a document into text. Implementations exist for PDF and plain text; CSV and images keep
/// their dedicated flows. XLSX/OFX/QFX readers can be added by conforming to this protocol.
protocol DocumentReading: Sendable {
    func read(_ data: Data, password: String?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DocumentText
}

struct PlainTextDocumentReader: DocumentReading {
    func read(_ data: Data, password: String?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DocumentText {
        let text = try CSVParser.decode(data)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw DocumentReadError.noText }
        return DocumentText(pages: [DocumentPage(index: 0, lines: lines, source: .plainText)])
    }
}

/// PDFKit text extraction with on-device Vision OCR for pages that have no embedded text
/// (scanned statements). Pages are processed one at a time so long statements don't hold every
/// rendered page in memory. The password, if any, is used only to unlock this in-memory copy.
struct PDFStatementReader: DocumentReading {
    var recognizer: any ReceiptTextRecognizing
    /// Render scale for OCR. 2× a PDF point is roughly 144 dpi, enough for statement text.
    var renderScale: CGFloat = 2

    func read(_ data: Data, password: String?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DocumentText {
        guard data.count <= DocumentLimits.maximumFileBytes else { throw DocumentReadError.tooLarge }
        guard let document = PDFDocument(data: data) else { throw DocumentReadError.unreadable }
        if document.isLocked {
            guard let password, !password.isEmpty else { throw DocumentReadError.passwordRequired }
            guard document.unlock(withPassword: password) else { throw DocumentReadError.wrongPassword }
        }
        let count = document.pageCount
        guard count > 0 else { throw DocumentReadError.noText }
        guard count <= DocumentLimits.maximumPages else { throw DocumentReadError.tooManyPages(count) }

        var pages: [DocumentPage] = []
        for i in 0..<count {
            try Task.checkCancellation()
            progress?(i + 1, count)
            guard let page = document.page(at: i) else { continue }
            let embedded = Self.lines(from: page.string ?? "")
            if embedded.joined().count >= DocumentLimits.minimumEmbeddedCharacters {
                pages.append(DocumentPage(index: i, lines: embedded, source: .embeddedText))
                continue
            }
            guard let image = render(page) else { continue }
            let lines = (try? await recognizer.recognizeText(in: image)) ?? []
            pages.append(DocumentPage(index: i, lines: lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                      source: .ocr))
        }
        guard pages.contains(where: { !$0.lines.isEmpty }) else { throw DocumentReadError.noText }
        return DocumentText(pages: pages)
    }

    static func lines(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * renderScale), height = Int(bounds.height * renderScale)
        guard width > 0, height > 0, width * height <= 40_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: renderScale, y: renderScale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
