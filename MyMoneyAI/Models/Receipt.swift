import Foundation
import SwiftData

enum ReceiptReviewStatus: String, Codable, Sendable { case pending, reviewed }

/// A receipt is an attachment. It is never counted as spending by itself.
/// The image lives in Application Support; only its relative path is stored here.
@Model
final class Receipt {
    @Attribute(.unique) var id: UUID
    var imageRelativePath: String
    var importedAt: Date
    var extractedText: String?
    var extractedMerchant: String?
    var extractedDate: Date?
    var extractedTotalMinorUnits: Int64?
    var currencyCode: String?
    var reviewStatusRaw: String
    var imageFingerprint: String?

    init(id: UUID = UUID(), imageRelativePath: String, importedAt: Date = .now, imageFingerprint: String? = nil) {
        self.id = id; self.imageRelativePath = imageRelativePath; self.importedAt = importedAt
        self.reviewStatusRaw = ReceiptReviewStatus.pending.rawValue; self.imageFingerprint = imageFingerprint
    }

    var reviewStatus: ReceiptReviewStatus {
        get { ReceiptReviewStatus(rawValue: reviewStatusRaw) ?? .pending }
        set { reviewStatusRaw = newValue.rawValue }
    }
}
