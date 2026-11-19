import Foundation
import CoreGraphics

/// Perceptual "difference hash" for receipt images. Re-importing the same screenshot or photo
/// produces the same (or nearly the same) 64-bit hash even after re-encoding.
enum ImageFingerprint {
    static let prefix = "dhash:"

    /// dHash over a 9×8 grayscale image (row-major): each bit is "left pixel brighter than right".
    static func dHash(grayscale p: [UInt8], width: Int = 9, height: Int = 8) -> UInt64 {
        precondition(p.count == width * height, "expected \(width * height) pixels")
        var hash: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                hash <<= 1
                if p[y * width + x] > p[y * width + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    static func string(_ hash: UInt64) -> String {
        let hex = String(hash, radix: 16)
        return prefix + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    static func parse(_ s: String) -> UInt64? {
        guard s.hasPrefix(prefix) else { return nil }
        return UInt64(s.dropFirst(prefix.count), radix: 16)
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    static func fingerprint(for image: CGImage) -> String? {
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        return drawn ? string(dHash(grayscale: pixels)) : nil
    }
}

struct ReceiptFingerprintEntry: Sendable, Hashable {
    var id: UUID
    var fingerprint: String?
}

struct DuplicateMatch: Identifiable, Hashable, Sendable {
    enum Reason: String, Sendable { case sameImage, similarImage, matchingTransaction }
    var reason: Reason
    var receiptId: UUID?
    var transactionId: UUID?

    var id: String { "\(reason.rawValue)-\(receiptId?.uuidString ?? "")-\(transactionId?.uuidString ?? "")" }

    var message: String {
        switch reason {
        case .sameImage: "This image has already been imported."
        case .similarImage: "A very similar image has already been imported."
        case .matchingTransaction: "An expense with the same amount and date already exists."
        }
    }
}

/// Warns about likely duplicate imports. It never blocks saving: the user decides.
enum DuplicateDetectionService {
    static let similarImageThreshold = 4

    static func findDuplicates(fingerprint: String?, amountMinorUnits: Int64?, date: Date?, merchant: String?,
                               receipts: [ReceiptFingerprintEntry], transactions: [TransactionRecord],
                               calendar: Calendar) -> [DuplicateMatch] {
        var result: [DuplicateMatch] = []
        if let hash = fingerprint.flatMap(ImageFingerprint.parse) {
            for r in receipts {
                guard let other = r.fingerprint.flatMap(ImageFingerprint.parse) else { continue }
                let d = ImageFingerprint.distance(hash, other)
                if d == 0 {
                    result.append(DuplicateMatch(reason: .sameImage, receiptId: r.id))
                } else if d <= similarImageThreshold {
                    result.append(DuplicateMatch(reason: .similarImage, receiptId: r.id))
                }
            }
        }
        if let amount = amountMinorUnits, amount > 0, let date {
            let day = calendar.dayRange(containing: date)
            let m = MerchantName.normalize(merchant)
            for t in transactions where t.transactionType == .expense && t.amountMinorUnits == amount && day.contains(t.transactionDate) {
                let other = MerchantName.normalize(t.merchant ?? t.title)
                if m.isEmpty || other.isEmpty || other.contains(m) || m.contains(other) {
                    result.append(DuplicateMatch(reason: .matchingTransaction, receiptId: t.receiptId, transactionId: t.id))
                }
            }
        }
        return result
    }
}
