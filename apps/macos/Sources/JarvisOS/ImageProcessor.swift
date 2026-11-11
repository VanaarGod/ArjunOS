import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales and re-encodes images before they go to a vision model: smaller requests, and a predictable JPEG format.
/// Transparency is flattened (transparent areas become black in the JPEG).
enum ImageProcessor {
    static func jpegBase64(from data: Data, maxDimension: Int = 1568, quality: Double = 0.85) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,      // respect EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data).base64EncodedString()
    }
}
