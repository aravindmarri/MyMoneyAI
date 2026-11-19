import UIKit

struct NormalizedImage {
    let jpeg: Data
    let cgImage: CGImage
}

/// Re-renders an imported image upright, scaled to at most `maxDimension` pixels, and re-encodes it
/// as JPEG. Re-encoding drops all metadata (including GPS location) before anything is stored.
enum ImageNormalizer {
    static func normalize(_ data: Data, maxDimension: CGFloat = 2400, quality: CGFloat = 0.82) -> NormalizedImage? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: quality), let cg = rendered.cgImage else { return nil }
        return NormalizedImage(jpeg: jpeg, cgImage: cg)
    }
}
