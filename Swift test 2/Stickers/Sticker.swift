import SwiftUI
import UIKit

// MARK: - CanvasBackground

enum CanvasBackground {
    case color(UIColor)
    case image(UIImage)
}

// MARK: - StickerKind

enum StickerKind {
    case photo(UIImage)
    case text(TextStickerContent)
    case music(MusicTrack)
    case video(videoURL: URL, thumbnail: UIImage, bgRemoved: Bool = false)
}

// MARK: - Sticker

struct Sticker: Identifiable, Equatable {
    let id: UUID
    var kind: StickerKind
    var position: CGPoint
    var scale: CGFloat
    var rotation: Angle
    var zIndex: Double

    init(id: UUID = UUID(), kind: StickerKind, position: CGPoint,
         scale: CGFloat = 1.0, rotation: Angle = .zero, zIndex: Double = 0) {
        self.id       = id
        self.kind     = kind
        self.position = position
        self.scale    = scale
        self.rotation = rotation
        self.zIndex   = zIndex
    }

    var image: UIImage? {
        switch kind {
        case .photo(let img): return img
        case .text(let c):    return c.image
        default:              return nil
        }
    }

    var musicTrack: MusicTrack? {
        if case .music(let t) = kind { return t }
        return nil
    }

    static func == (lhs: Sticker, rhs: Sticker) -> Bool {
        guard lhs.id == rhs.id, lhs.position == rhs.position,
              lhs.scale == rhs.scale, lhs.rotation == rhs.rotation,
              lhs.zIndex == rhs.zIndex else { return false }
        switch (lhs.kind, rhs.kind) {
        case (.photo(let a), .photo(let b)):
            return a === b
        case (.video(let ua, let ta, let ba), .video(let ub, let tb, let bb)):
            return ua == ub && ta === tb && ba == bb
        case (.text(let a), .text(let b)):
            return a.text == b.text && a.fontIndex == b.fontIndex &&
                   a.colorIndex == b.colorIndex && a.wrapWidth == b.wrapWidth &&
                   a.alignment == b.alignment && a.bgStyle == b.bgStyle
        case (.music(let a), .music(let b)):
            return a.id == b.id
        default: return false
        }
    }
}
