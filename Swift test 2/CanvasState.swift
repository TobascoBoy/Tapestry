import Foundation
import UIKit
import ImageIO

// MARK: - Canvas Mode

enum CanvasMode: String, Codable {
    case infinite   // pan/pinch infinite canvas (default)
    case vertical   // tall vertically-scrollable feed canvas
}

// MARK: - Codable canvas snapshot

struct CanvasState: Codable {
    var background: BackgroundState
    var stickers:   [StickerState]

    struct BackgroundState: Codable {
        var type: String                  // "color" | "image"
        var colorComponents: [Double]?    // r, g, b, a  (0-1)
        var imageFilename:   String?
    }
}

struct StickerState: Codable {
    var id:               UUID
    var type:             String    // "photo" | "text" | "music" | "video"
    var x:                Double
    var y:                Double
    var scale:            Double
    var rotationRadians:  Double
    var zIndex:           Double

    // photo
    var imageFilename:    String?

    // text
    var textString:       String?
    var fontIndex:        Int?
    var colorIndex:       Int?
    var textWrapWidth:    Double?
    var textAlignment:    Int?
    var textBGStyle:      Int?

    // music
    var musicID:                    String?
    var musicTitle:                 String?
    var musicArtist:                String?
    var musicArtworkURLString:      String?
    var musicPreviewURLString:      String?
    var musicArtworkImageFilename:  String?   // cached artwork image on disk

    // video
    var videoFilename:          String?
    var videoThumbnailFilename: String?
    var bgRemoved:              Bool?
}

// MARK: - Sticker image / video storage

enum StickerStorage {
    private static let imagesDir = "sticker-images"
    private static let videosDir = "sticker-videos"

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func saveImage(_ image: UIImage, filename: String) {
        let dir = documents.appendingPathComponent(imagesDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Always PNG — preserves alpha channel for background-removed images
        if let data = image.pngData() {
            try? data.write(to: dir.appendingPathComponent(filename))
        }
    }

    static func saveGIF(_ data: Data, filename: String) {
        let dir = documents.appendingPathComponent(imagesDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(filename))
    }

    static func loadImage(filename: String) -> UIImage? {
        let url = documents.appendingPathComponent(imagesDir).appendingPathComponent(filename)
        if filename.hasSuffix(".gif") {
            return UIImage.animatedGIF(from: url)
        }
        return UIImage(contentsOfFile: url.path)
    }

    static func saveVideo(from sourceURL: URL, filename: String) {
        let dir = documents.appendingPathComponent(videosDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? FileManager.default.copyItem(at: sourceURL, to: dest)
    }

    static func loadVideoURL(filename: String) -> URL? {
        let url = documents.appendingPathComponent(videosDir).appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

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
