import Foundation
import Testing
import UIKit
@testable import TallySeam

// MARK: - OCR line assembly and on-device Vision

@Suite struct OCRTests {
    @Test func assemblerJoinsColumnsOnTheSameLine() {
        let fragments = [
            OCRFragment(text: "8.39", minX: 0.8, midY: 0.30, height: 0.04),
            OCRFragment(text: "CORNER CAFE", minX: 0.2, midY: 0.90, height: 0.05),
            OCRFragment(text: "TOTAL", minX: 0.1, midY: 0.31, height: 0.04),
            OCRFragment(text: "TAX", minX: 0.1, midY: 0.40, height: 0.04),
            OCRFragment(text: "0.64", minX: 0.8, midY: 0.395, height: 0.04),
        ]
        #expect(OCRLineAssembler.lines(from: fragments) == ["CORNER CAFE", "TAX  0.64", "TOTAL  8.39"])
    }

    /// Renders a synthetic receipt and runs the real Vision recognizer offline on the simulator.
    @Test func visionReadsSyntheticReceiptEndToEnd() async throws {
        let rows: [(String, String)] = [("CORNER CAFE", ""), ("03/15/2024", ""), ("Latte", "4.50"), ("Muffin", "3.25"),
                                        ("SUBTOTAL", "7.75"), ("TAX", "0.64"), ("TOTAL", "8.39")]
        let image = SyntheticReceipt.render(rows)
        let png = try #require(image.pngData())
        let normalized = try #require(ImageNormalizer.normalize(png))
        let lines = try await VisionReceiptOCRService().recognizeText(in: normalized.cgImage)
        let parsed = ReceiptParserService().parse(lines: lines, defaultCurrency: "USD")
        #expect(parsed.total?.value == 839, "Recognized lines: \(lines)")
        #expect(parsed.merchant?.value.lowercased().contains("corner") == true, "Recognized lines: \(lines)")
    }
}

enum SyntheticReceipt {
    static func render(_ rows: [(String, String)], width: CGFloat = 700) -> UIImage {
        let lineHeight: CGFloat = 64
        let size = CGSize(width: width, height: CGFloat(rows.count) * lineHeight + 60)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let font = UIFont.monospacedSystemFont(ofSize: 34, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, row) in rows.enumerated() {
                let y = 30 + CGFloat(i) * lineHeight
                (row.0 as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: attrs)
                let amount = row.1 as NSString
                let w = amount.size(withAttributes: attrs).width
                amount.draw(at: CGPoint(x: width - 40 - w, y: y), withAttributes: attrs)
            }
        }
    }
}

// MARK: - Fingerprints and duplicates

@Suite struct DuplicateDetectionTests {
    let calendar = Calendar(identifier: .gregorian)

    @Test func dHashOfGradientAndRoundTrip() {
        let descending = (0..<8).flatMap { _ in (0..<9).map { UInt8(255 - $0 * 20) } }
        let hash = ImageFingerprint.dHash(grayscale: descending)
        #expect(hash == UInt64.max)                      // every left pixel is brighter
        let s = ImageFingerprint.string(hash)
        #expect(s == "dhash:ffffffffffffffff")
        #expect(ImageFingerprint.parse(s) == hash)
        #expect(ImageFingerprint.parse("garbage") == nil)
        #expect(ImageFingerprint.string(1) == "dhash:0000000000000001")
    }

    @Test func sameImageReencodedHasSameOrNearFingerprint() throws {
        let image = SyntheticReceipt.render([("FRESH MART", ""), ("TOTAL", "4.78")])
        let png = try #require(image.pngData())
        let jpeg = try #require(image.jpegData(compressionQuality: 0.6))
        let a = try #require(ImageNormalizer.normalize(png))
        let b = try #require(ImageNormalizer.normalize(jpeg))
        let fa = try #require(ImageFingerprint.fingerprint(for: a.cgImage).flatMap(ImageFingerprint.parse))
        let fb = try #require(ImageFingerprint.fingerprint(for: b.cgImage).flatMap(ImageFingerprint.parse))
        #expect(ImageFingerprint.distance(fa, fb) <= DuplicateDetectionService.similarImageThreshold)
    }

    @Test func detectsSameAndSimilarImages() {
        let existing = [ReceiptFingerprintEntry(id: UUID(), fingerprint: ImageFingerprint.string(0b1010)),
                        ReceiptFingerprintEntry(id: UUID(), fingerprint: ImageFingerprint.string(0b1011)),
                        ReceiptFingerprintEntry(id: UUID(), fingerprint: ImageFingerprint.string(UInt64.max))]
        let matches = DuplicateDetectionService.findDuplicates(fingerprint: ImageFingerprint.string(0b1010), amountMinorUnits: nil,
                                                               date: nil, merchant: nil, receipts: existing, transactions: [], calendar: calendar)
        #expect(matches.map(\.reason) == [.sameImage, .similarImage])
        #expect(matches.map(\.receiptId) == [existing[0].id, existing[1].id])
    }

    @Test func detectsMatchingExpenseSameDaySameAmount() {
        let day = calendar.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 9))!
        let later = calendar.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 18))!
        let existing = TransactionRecord(transactionDate: day, amountMinorUnits: 839, merchant: "Corner Cafe", title: "Coffee",
                                         transactionType: .expense)
        let otherMerchant = TransactionRecord(transactionDate: day, amountMinorUnits: 839, merchant: "Book Nook", title: "Book",
                                              transactionType: .expense)
        let income = TransactionRecord(transactionDate: day, amountMinorUnits: 839, title: "Refund", transactionType: .income)
        let matches = DuplicateDetectionService.findDuplicates(fingerprint: nil, amountMinorUnits: 839, date: later,
                                                               merchant: "CORNER CAFE #12", receipts: [],
                                                               transactions: [existing, otherMerchant, income], calendar: calendar)
        #expect(matches.map(\.transactionId) == [existing.id])
        #expect(DuplicateDetectionService.findDuplicates(fingerprint: nil, amountMinorUnits: 840, date: later, merchant: nil,
                                                         receipts: [], transactions: [existing], calendar: calendar).isEmpty)
    }
}

// MARK: - Category suggestions

@Suite struct CategorySuggestionTests {
    let groceries = CategoryOption(id: UUID(), name: "Groceries", kind: .expense)
    let restaurants = CategoryOption(id: UUID(), name: "Restaurants", kind: .expense)
    let fuel = CategoryOption(id: UUID(), name: "Fuel", kind: .expense)
    let utilities = CategoryOption(id: UUID(), name: "Utilities", kind: .expense)
    let salary = CategoryOption(id: UUID(), name: "Salary", kind: .income)
    var options: [CategoryOption] { [groceries, restaurants, fuel, utilities, salary] }
    let service = HeuristicCategorySuggestionService()

    @Test func merchantNormalization() {
        #expect(MerchantName.normalize("STARBUCKS #1234") == "starbucks")
        #expect(MerchantName.normalize("Café Olé") == "cafe ole")
        #expect(MerchantName.normalize(nil) == "")
    }

    @Test func userHistoryWinsOverDirectory() {
        let old = TransactionRecord(transactionDate: Date(timeIntervalSince1970: 1_000), amountMinorUnits: 1, merchant: "Shell",
                                    title: "x", transactionType: .expense, categoryId: fuel.id)
        let recent = TransactionRecord(transactionDate: Date(timeIntervalSince1970: 2_000), amountMinorUnits: 1, merchant: "SHELL #55",
                                       title: "x", transactionType: .expense, categoryId: groceries.id)
        let s = service.suggest(merchant: "Shell", receiptText: nil, kind: .expense, categories: options, history: [old, recent])
        #expect(s == CategorySuggestion(categoryId: groceries.id, source: .history))
    }

    @Test func historyIgnoresDeletedCategories() {
        let gone = TransactionRecord(transactionDate: .now, amountMinorUnits: 1, merchant: "Shell", title: "x",
                                     transactionType: .expense, categoryId: UUID())
        let s = service.suggest(merchant: "Shell", receiptText: nil, kind: .expense, categories: options, history: [gone])
        #expect(s == CategorySuggestion(categoryId: fuel.id, source: .merchantDirectory))
    }

    @Test func directoryUsesLongestWholeWordMatch() {
        #expect(service.suggest(merchant: "Uber Eats", receiptText: nil, kind: .expense, categories: options, history: [])?.categoryId == restaurants.id)
        #expect(service.suggest(merchant: "BPM Studio", receiptText: nil, kind: .expense, categories: options, history: []) == nil)
    }

    @Test func keywordsUseMerchantAndHeaderOnly() {
        let s = service.suggest(merchant: "Sunny Side Diner", receiptText: nil, kind: .expense, categories: options, history: [])
        #expect(s == CategorySuggestion(categoryId: restaurants.id, source: .keyword))
        let text = "Green Leaf\n123 Road\nThanks\nBottled water 1.00\nElectric toothbrush 20.00"
        #expect(service.suggest(merchant: "Green Leaf", receiptText: text, kind: .expense, categories: options, history: []) == nil)
    }

    @Test func respectsRequestedKind() {
        #expect(service.suggest(merchant: "Starbucks", receiptText: nil, kind: .income, categories: options, history: []) == nil)
    }
}
