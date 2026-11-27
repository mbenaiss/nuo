import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageCompressor {
    static let maxBytes = 1_500_000

    /// Re-encodes as JPEG under 1.5 MB, downscaling to 2048 px first (gateway attachment budget).
    static func jpeg(from data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            var dimension: CGFloat = 2048
            var quality: CGFloat = 0.82
            while dimension >= 256 {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: dimension,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                while quality > 0.45 {
                    if let encoded = encode(image, quality: quality), encoded.count <= maxBytes { return encoded }
                    quality -= 0.12
                }
                dimension *= 0.75
                quality = 0.7
            }
            return nil
        }.value
    }

    private static func encode(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
