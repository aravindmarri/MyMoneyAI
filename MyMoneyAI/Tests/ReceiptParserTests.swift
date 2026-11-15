import Foundation
import Testing
@testable import MyMoneyAI

/// All receipts below are synthetic: invented merchants, items and amounts.
@Suite struct ReceiptParserTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()
    var parser: ReceiptParserService {
        ReceiptParserService(calendar: calendar, referenceDate: calendar.date(from: DateComponents(year: 2024, month: 6, day: 1))!)
    }
    func ymd(_ d: Date) -> [Int] { [calendar.component(.year, from: d), calendar.component(.month, from: d), calendar.component(.day, from: d)] }

    @Test func standardCafeReceipt() {
        let r = parser.parse(text: """
        CORNER CAFE
        1200 Example Ave
        Tel 555-0100
        03/15/2024 08:42
        Latte              4.50
        Blueberry Muffin   3.25
        SUBTOTAL           7.75
        TAX 8.25%          0.64
        TOTAL              8.39
        VISA **** 1234     8.39
        THANK YOU
        """, defaultCurrency: "USD")
        #expect(r.merchant?.value == "Corner Cafe")
        #expect(r.date.map { ymd($0.value) } == [2024, 3, 15])
        #expect(r.total == ParsedValue(value: 839, confidence: .high))
        #expect(r.subtotalMinorUnits == 775)
        #expect(r.taxMinorUnits == 64)      // not 8.25 (that's the tax rate)
    }

    @Test func changeAndCashAreNeverTheTotal() {
        let r = parser.parse(text: """
        Fresh Mart
        Bananas      1.29
        Bread        3.49
        TOTAL        4.78
        CASH        20.00
        CHANGE      15.22
        """, defaultCurrency: "USD")
        #expect(r.total?.value == 478)
        #expect(r.candidates.contains { $0.kind == .tendered && $0.minorUnits == 2_000 })
        #expect(r.candidates.contains { $0.kind == .change && $0.minorUnits == 1_522 })
    }

    @Test func labelsAndAmountsInSeparateColumns() {
        // OCR sometimes returns the label column and the amount column as separate lines.
        let r = parser.parse(text: """
        Book Nook
        SUBTOTAL
        TAX
        TOTAL
        20.00
        1.60
        21.60
        """, defaultCurrency: "USD")
        #expect(r.subtotalMinorUnits == 2_000)
        #expect(r.taxMinorUnits == 160)
        #expect(r.total == ParsedValue(value: 2_160, confidence: .high))
    }

    @Test func subtotalTaxDiscountReconciliation() {
        let r = parser.parse(text: """
        HOME GOODS PLUS
        Lamp          40.00
        Discount      -5.00
        Subtotal      35.00
        Sales Tax      2.80
        Amount Due    37.80
        """, defaultCurrency: "USD")
        #expect(r.discountMinorUnits == 500)
        #expect(r.total == ParsedValue(value: 3_780, confidence: .high))
    }

    @Test func discountAfterSubtotalIsSubtractedWhenInferringTotal() {
        let r = parser.parse(text: """
        Garden Supply
        Subtotal      30.00
        Coupon         3.00
        Tax            2.16
        """, defaultCurrency: "USD")
        #expect(r.total == ParsedValue(value: 2_916, confidence: .medium))
    }

    @Test func grandTotalWinsOverItemTotalsAndTip() {
        let r = parser.parse(text: """
        Bistro Nine
        Total food    50.00
        Subtotal      50.00
        Tax            4.00
        Tip           10.00
        Grand Total   64.00
        """, defaultCurrency: "USD")
        #expect(r.total == ParsedValue(value: 6_400, confidence: .high))
    }

    @Test func noLabelsFallsBackToLargestWithLowConfidence() {
        let r = parser.parse(text: """
        Tiny Kiosk
        Gum      1.50
        Water    2.25
        """, defaultCurrency: "USD")
        #expect(r.total == ParsedValue(value: 225, confidence: .low))
    }

    @Test func totalWithoutReconciliationIsMediumConfidence() {
        let r = parser.parse(text: "Quick Stop\nTOTAL 12.00", defaultCurrency: "USD")
        #expect(r.total == ParsedValue(value: 1_200, confidence: .medium))
    }

    @Test func thousandsSeparatorsAndEuropeanFormat() {
        #expect(parser.parse(text: "Electronics Hub\nTOTAL $1,249.99", defaultCurrency: "USD").total?.value == 124_999)
        let eu = parser.parse(text: "Marktplatz\nSUMME\nTOTAL EUR 1.234,56", defaultCurrency: "USD")
        #expect(eu.total?.value == 123_456)
        #expect(eu.currencyCode == ParsedValue(value: "EUR", confidence: .high))
    }

    @Test func ocrMisreadZeroInTotal() {
        #expect(parser.parse(text: "Shop\nT0TAL 9.99", defaultCurrency: "USD").total?.value == 999)
    }

    @Test(arguments: [
        ("2024-03-15", [2024, 3, 15], ParseConfidence.high),
        ("Mar 15, 2024", [2024, 3, 15], .high),
        ("15 March 2024", [2024, 3, 15], .high),
        ("15/03/2024", [2024, 3, 15], .high),      // day > 12: unambiguous day-first
        ("03/04/2024", [2024, 3, 4], .medium),     // ambiguous: US month-first assumed
        ("3-15-24", [2024, 3, 15], .medium),       // two-digit year
    ] as [(String, [Int], ParseConfidence)])
    func dateFormats(text: String, expected: [Int], confidence: ParseConfidence) {
        let d = parser.parse(text: "Store\nDate: \(text)\nTOTAL 1.00", defaultCurrency: "USD").date
        #expect(d.map { ymd($0.value) } == expected)
        #expect(d?.confidence == confidence)
    }

    @Test func rejectsImpossibleAndFutureDates() {
        #expect(parser.parse(text: "Store\n02/30/2024", defaultCurrency: "USD").date == nil)
        #expect(parser.parse(text: "Store\n12/25/2030", defaultCurrency: "USD").date == nil)
    }

    @Test func dateDigitsAreNotReadAsAmounts() {
        let r = parser.parse(text: "Store\n03.15.24\nTOTAL 5.00", defaultCurrency: "USD")
        #expect(r.candidates.map(\.minorUnits) == [500])
    }

    @Test func merchantSkipsWelcomeAddressAndPhone() {
        let r = parser.parse(text: """
        Welcome to Sunny Side Diner
        456 Sample Street
        """, defaultCurrency: "USD")
        #expect(r.merchant?.value == "Sunny Side Diner")
        let r2 = parser.parse(text: "RECEIPT\n789 Main St\nGreen Leaf Market\nTOTAL 3.00", defaultCurrency: "USD")
        #expect(r2.merchant == ParsedValue(value: "Green Leaf Market", confidence: .low))
    }

    @Test func currencyDetection() {
        #expect(parser.parse(text: "Shop\nTotal £4.20", defaultCurrency: "USD").currencyCode?.value == "GBP")
        #expect(parser.parse(text: "Shop\nTotal $4.20", defaultCurrency: "CAD").currencyCode == ParsedValue(value: "CAD", confidence: .low))
        #expect(parser.parse(text: "Shop\nTotal 4.20", defaultCurrency: "USD").currencyCode == nil)
    }

    @Test func emptyOrGarbageInput() {
        let r = parser.parse(text: "\n  \n###\n", defaultCurrency: "USD")
        #expect(r.total == nil)
        #expect(r.merchant == nil)
        #expect(r.date == nil)
    }
}

@Suite struct ReceiptDraftMappingTests {
    @Test func parsedValuesFillDraftButNothingIsSaved() {
        var parsed = ParsedReceipt()
        parsed.total = ParsedValue(value: 1_999, confidence: .medium)
        parsed.merchant = ParsedValue(value: "Corner Cafe", confidence: .medium)
        let draft = ReceiptScannerViewModel.makeDraft(from: parsed, defaultCurrency: "USD")
        #expect(draft.amountText == "19.99")
        #expect(draft.merchant == "Corner Cafe")
        #expect(draft.type == .expense)
        #expect(draft.source == .receiptOCR)
        #expect(draft.editingId == nil)
    }

    @Test func ocrFailureGivesEmptyManualDraft() {
        let draft = ReceiptScannerViewModel.makeDraft(from: nil, defaultCurrency: "EUR")
        #expect(draft.amountText.isEmpty)
        #expect(draft.currencyCode == "EUR")
    }
}
