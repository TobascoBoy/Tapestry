import UIKit
import ImageIO

// MARK: - GIF decoding

extension UIImage {
    /// Decodes a GIF file URL into an animated UIImage (multiple frames + duration).
    /// Returns a static UIImage for single-frame GIFs or on failure.
    static func animatedGIF(from url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return animatedGIF(from: data)
    }

    /// Decodes raw GIF bytes into an animated UIImage.
    static func animatedGIF(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            // Single-frame GIF — treat as a regular image
            guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return UIImage(cgImage: cg)
        }

        var frames: [UIImage] = []
        var totalDuration: Double = 0

        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let props  = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
            let gif    = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            // Prefer unclamped delay; fall back to clamped; default 0.1 s
            let delay  = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
                      ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double)
                      ?? 0.1
            frames.append(UIImage(cgImage: cg))
            totalDuration += max(delay, 0.02)   // clamp very fast frames
        }

        return UIImage.animatedImage(with: frames, duration: totalDuration)
    }
}

// MARK: - GIF detection

extension Data {
    /// Returns true when the bytes start with the GIF magic number ("GIF87a" or "GIF89a").
    /// Whether the GIF is animated is determined downstream by checking frame count.
    var isGIF: Bool {
        count >= 3 && self[0] == 0x47 && self[1] == 0x49 && self[2] == 0x46  // "GIF"
    }
}
