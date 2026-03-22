import Foundation

// MARK: - TapestryType

enum TapestryType: String, Codable, Identifiable {
    case personal
    case group
    var id: Self { self }
}

// MARK: - CoverShape

enum CoverShape: String, Codable {
    case square, wide, tall

    /// Cycles to the next shape in order.
    var next: CoverShape {
        switch self {
        case .square: return .wide
        case .wide:   return .tall
        case .tall:   return .square
        }
    }

    var systemImage: String {
        switch self {
        case .square: return "square"
        case .wide:   return "rectangle"
        case .tall:   return "rectangle.portrait"
        }
    }

    var label: String {
        switch self {
        case .square: return "Square"
        case .wide:   return "Wide"
        case .tall:   return "Tall"
        }
    }
}

// MARK: - Tapestry

struct Tapestry: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var description: String
    var thumbnailFilename: String?   // local disk cache
    var thumbnailURL: String?        // remote Supabase Storage URL
    let createdAt: Date
    var updatedAt: Date
    var type: TapestryType
    var canvasData: String?          // JSON canvas snapshot
    var ownerID: UUID?               // nil only for legacy local-only tapestries
    var canvasMode: CanvasMode       // stored in Supabase so all members share the same mode
    var coverShape: CoverShape       // grid cell shape — synced to Supabase so visitors see owner's layout
    var displayOrder: Int            // ordering in profile grid — synced to Supabase
    var isPinned: Bool               // pinned to top of profile — synced to Supabase

    init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        thumbnailFilename: String? = nil,
        thumbnailURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        type: TapestryType = .personal,
        canvasData: String? = nil,
        ownerID: UUID? = nil,
        canvasMode: CanvasMode = .infinite,
        coverShape: CoverShape = .square,
        displayOrder: Int = 0,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.thumbnailFilename = thumbnailFilename
        self.thumbnailURL = thumbnailURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.type = type
        self.canvasData = canvasData
        self.ownerID = ownerID
        self.canvasMode = canvasMode
        self.coverShape = coverShape
        self.displayOrder = displayOrder
        self.isPinned = isPinned
    }
}
