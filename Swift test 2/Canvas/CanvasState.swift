import Foundation

// MARK: - Canvas Mode

enum CanvasMode: String, Codable {
    case infinite   // pan/pinch infinite canvas (default)
    case vertical   // tall vertically-scrollable feed canvas
}

// MARK: - StickerTypeKey
//
// Single source of truth for the sticker "type" string stored in JSON.
// Changing a sticker type only requires updating this constant.

enum StickerTypeKey {
    static let photo = "photo"
    static let text  = "text"
    static let music = "music"
    static let video = "video"
}

// MARK: - Codable canvas snapshot

struct CanvasState: Codable {
    var background: BackgroundState
    var stickers:   [StickerState]

    struct BackgroundState: Codable {
        var type: String                  // "color" | "image" | "live_scene"
        var colorComponents: [Double]?    // r, g, b, a  (0-1)
        var imageFilename:   String?
        var imageURL:        String?      // Supabase Storage URL
        var sceneName:       String?      // LiveBackgroundScene raw value
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

    // photo (local)
    var imageFilename:    String?
    // photo (Supabase)
    var imageURL:         String?

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

    // video (local)
    var videoFilename:          String?
    var videoThumbnailFilename: String?
    // video (Supabase)
    var videoURL:               String?
    var videoThumbnailURL:      String?
    var bgRemoved:              Bool?
}
