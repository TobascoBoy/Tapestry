import Foundation
import UIKit
import Supabase

// MARK: - StickerAssetUploader
//
// Uploads sticker assets (photos, GIFs, videos) to Supabase Storage and
// returns the public URL string. Also handles downloading remote assets to
// the local disk cache so loadCanvas() can serve them instantly.

enum StickerAssetUploader {

    private static let bucket = "sticker-assets"

    // MARK: - Upload

    /// Upload a static or background-removed photo. Always PNG to preserve alpha.
    static func uploadImage(_ image: UIImage, stickerID: UUID) async throws -> String {
        guard let data = image.pngData() else { throw AssetError.encodingFailed }
        let path = "\(stickerID.uuidString).png"
        try await supabase.storage
            .from(bucket)
            .upload(path, data: data, options: .init(contentType: "image/png", upsert: true))
        return try supabase.storage.from(bucket).getPublicURL(path: path).absoluteString
    }

    /// Upload a GIF by reading its already-saved local file (preserves animation frames).
    static func uploadGIF(stickerID: UUID) async throws -> String {
        let filename = "\(stickerID.uuidString).gif"
        let localURL = StickerStorage.imagesDirURL.appendingPathComponent(filename)
        let data = try Data(contentsOf: localURL)
        try await supabase.storage
            .from(bucket)
            .upload(filename, data: data, options: .init(contentType: "image/gif", upsert: true))
        return try supabase.storage.from(bucket).getPublicURL(path: filename).absoluteString
    }

    /// Upload a video file.
    static func uploadVideo(from localURL: URL, stickerID: UUID) async throws -> String {
        let data = try Data(contentsOf: localURL)
        let path = "\(stickerID.uuidString).mp4"
        try await supabase.storage
            .from(bucket)
            .upload(path, data: data, options: .init(contentType: "video/mp4", upsert: true))
        return try supabase.storage.from(bucket).getPublicURL(path: path).absoluteString
    }

    /// Upload a video thumbnail.
    static func uploadVideoThumbnail(_ image: UIImage, stickerID: UUID) async throws -> String {
        guard let data = image.pngData() else { throw AssetError.encodingFailed }
        let path = "\(stickerID.uuidString)_thumb.png"
        try await supabase.storage
            .from(bucket)
            .upload(path, data: data, options: .init(contentType: "image/png", upsert: true))
        return try supabase.storage.from(bucket).getPublicURL(path: path).absoluteString
    }

    /// Upload a canvas background image.
    static func uploadBackground(_ image: UIImage, tapestryID: UUID) async throws -> String {
        guard let data = image.pngData() else { throw AssetError.encodingFailed }
        let path = "bg_\(tapestryID.uuidString).png"
        try await supabase.storage
            .from(bucket)
            .upload(path, data: data, options: .init(contentType: "image/png", upsert: true))
        return try supabase.storage.from(bucket).getPublicURL(path: path).absoluteString
    }

    // MARK: - Download to local cache

    /// Returns a local cached URL for a remote asset, downloading it first if needed.
    /// Used by loadCanvas() so stickers render from disk rather than network on every open.
    ///
    /// Retries up to 3 times with short backoff to handle CDN propagation lag after
    /// a fresh Supabase Storage upload. HTTP errors (e.g. 404 while the CDN catches up)
    /// are never written to the cache — previously this caused permanent "cached 404" bugs
    /// where every subsequent call found a stale error body on disk and returned it silently.
    static func cachedLocalURL(for remoteURLString: String, ext: String) async throws -> URL {
        let cacheURL = cacheFileURL(for: remoteURLString, ext: ext)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }
        guard let remoteURL = URL(string: remoteURLString) else { throw AssetError.invalidURL }

        var lastError: Error = AssetError.downloadFailed
        for attempt in 0..<3 {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(600 * attempt))
            }
            do {
                let (tmpURL, response) = try await URLSession.shared.download(from: remoteURL)
                // Reject non-2xx — otherwise we'd cache an HTML error page as the image.
                if let http = response as? HTTPURLResponse, http.statusCode / 100 != 2 {
                    try? FileManager.default.removeItem(at: tmpURL)
                    lastError = AssetError.httpError(http.statusCode)
                    continue
                }
                let dir = cacheURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: tmpURL, to: cacheURL)
                return cacheURL
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Returns the local cache path for a remote URL without downloading.
    /// Use this to check if an asset is already cached before going to the network.
    static func cacheFileURL(for remoteURLString: String, ext: String) -> URL {
        let hash = abs(remoteURLString.hashValue)
        return cacheDir.appendingPathComponent("\(hash).\(ext)")
    }

    private static var cacheDir: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sticker-asset-cache")
    }

    // MARK: - Errors

    enum AssetError: Error {
        case encodingFailed
        case invalidURL
        case downloadFailed
        case httpError(Int)
    }
}

// MARK: - StickerStorage extension

extension StickerStorage {
    /// Exposed so StickerAssetUploader can locate GIF files for upload.
    static var imagesDirURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sticker-images")
    }
}
