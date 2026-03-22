import UIKit
import SwiftUI

// MARK: - CanvasSerializer
//
// Shared serialization helpers used by both saveCanvas() and saveCanvasLocalBackup().
// Eliminates ~40 lines of duplicated color/sticker encoding logic between the two paths.

enum CanvasSerializer {

    // MARK: Background

    /// Converts a CanvasBackground into its Codable BackgroundState.
    /// For .image, only the type is set — the caller must supply imageURL separately
    /// (async upload in saveCanvas, nil in local backup).
    static func serializeBackground(_ bg: CanvasBackground) -> CanvasState.BackgroundState {
        var state = CanvasState.BackgroundState(type: "color")
        switch bg {
        case .color(let c):
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            state.colorComponents = [r, g, b, a].map { Double($0) }
        case .image:
            state.type = "image"
        case .liveScene(let scene):
            state.type = "live_scene"
            state.sceneName = scene.rawValue
        }
        return state
    }

    // MARK: Stickers (sync — cached URLs only, no uploads)

    /// Serializes a sticker using only already-cached remote URLs — no async uploads.
    ///
    /// - Returns a fully populated StickerState for all types, using cached URLs for
    ///   photo/video. Used by saveCanvasLocalBackup() and the immediate (text/music-only)
    ///   fast-path in saveCanvas().
    /// - Returns nil only for photo/video stickers with no cached URL when
    ///   `requiresURL` is true, so the caller can skip incomplete records.
    static func serializeSticker(
        _ sticker: Sticker,
        uploadedURLs: [UUID: String],
        uploadedThumbnailURLs: [UUID: String],
        requireURL: Bool = false
    ) -> StickerState? {
        var s = StickerState(
            id: sticker.id, type: "",
            x: sticker.position.x, y: sticker.position.y,
            scale: sticker.scale,
            rotationRadians: sticker.rotation.radians,
            zIndex: sticker.zIndex
        )
        switch sticker.kind {
        case .photo(let img):
            s.type = StickerTypeKey.photo
            s.imageFilename = img.images != nil
                ? "\(sticker.id.uuidString).gif"
                : "\(sticker.id.uuidString).png"
            s.imageURL = uploadedURLs[sticker.id]
        case .photoLoading:
            return nil  // transient remote placeholder — never persist
        case .text(let c):
            applyText(c, to: &s)
        case .music(let t):
            applyMusic(t, to: &s)
        case .video(_, _, let bgRemoved):
            s.type = StickerTypeKey.video
            s.bgRemoved = bgRemoved
            s.videoURL = uploadedURLs[sticker.id]
            s.videoThumbnailURL = uploadedThumbnailURLs[sticker.id]
            if requireURL && s.videoThumbnailURL == nil { return nil }
        }
        return s
    }

    // MARK: Field helpers (reused by the async upload path in saveCanvas)

    static func applyText(_ c: TextStickerContent, to s: inout StickerState) {
        s.type = StickerTypeKey.text
        s.textString    = c.text
        s.fontIndex     = c.fontIndex
        s.colorIndex    = c.colorIndex
        s.textWrapWidth = Double(c.wrapWidth)
        s.textAlignment = c.alignment
        s.textBGStyle   = c.bgStyle
    }

    static func applyMusic(_ t: MusicTrack, to s: inout StickerState) {
        s.type = StickerTypeKey.music
        s.musicID               = t.id
        s.musicTitle            = t.title
        s.musicArtist           = t.artistName
        s.musicArtworkURLString = t.artworkURL?.absoluteString
        s.musicPreviewURLString = t.previewURL?.absoluteString
    }
}
