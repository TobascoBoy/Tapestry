import UIKit

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
