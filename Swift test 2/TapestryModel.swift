import Foundation
import Observation
import UIKit
import Supabase

// MARK: - Tapestry Type

enum TapestryType: String, Codable, Identifiable {
    case personal
    case group
    var id: Self { self }
}

// MARK: - Tapestry Model

struct Tapestry: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var description: String
    var thumbnailFilename: String?   // local disk cache
    let createdAt: Date
    var updatedAt: Date
    var type: TapestryType
    var canvasData: String?          // JSON canvas snapshot

    init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        thumbnailFilename: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        type: TapestryType = .personal,
        canvasData: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.thumbnailFilename = thumbnailFilename
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.type = type
        self.canvasData = canvasData
    }
}

// MARK: - Supabase row shapes

/// What we send to Supabase on insert
private struct TapestryInsert: Encodable {
    let id: UUID
    let ownerID: UUID
    let title: String
    let description: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID      = "owner_id"
        case title
        case description
        case type
    }
}

/// What we receive back from Supabase on select.
/// Dates are decoded as raw strings to avoid JSONDecoder ISO-8601 format mismatches
/// (Supabase returns "2024-01-15T10:30:00.123456+00:00" which the default decoder rejects).
private struct TapestryRow: Decodable {
    let id: UUID
    let title: String
    let description: String
    let type: String
    let createdAt: String
    let updatedAt: String
    let canvasData: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case type
        case createdAt  = "created_at"
        case updatedAt  = "updated_at"
        case canvasData = "canvas_data"
    }

    func toTapestry() -> Tapestry {
        Tapestry(
            id: id,
            title: title,
            description: description,
            thumbnailFilename: nil,
            createdAt: Self.parseDate(createdAt),
            updatedAt: Self.parseDate(updatedAt),
            type: TapestryType(rawValue: type) ?? .personal,
            canvasData: canvasData
        )
    }

    static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ string: String) -> Date {
        isoFull.date(from: string) ?? isoBasic.date(from: string) ?? Date()
    }
}

// MARK: - TapestryStore

@Observable
final class TapestryStore {
    private(set) var tapestries: [Tapestry] = []
    var debugMessage: String = ""   // visible error surfacing for diagnosis

    var personal: [Tapestry] { tapestries.filter { $0.type == .personal } }
    var group: [Tapestry]    { tapestries.filter { $0.type == .group } }

    // Set when user signs in so add/delete can attach owner_id
    var currentUserID: UUID?

    private static let thumbDir    = "tapestry-thumbs"
    private static let thumbsKey   = "tapestry_thumbnail_filenames"  // UserDefaults key

    // Thumbnail cache — observable so writes immediately re-render any subscribed view
    private var thumbnailCache: [UUID: UIImage] = [:]
    // Viewport cache — not observed (only read during profile re-renders, not used currently)
    @ObservationIgnored private var viewportCache:  [UUID: (offset: CGSize, scale: CGFloat)] = [:]

    // Persisted map of tapestryID → thumbnail filename
    private var savedThumbnailMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.thumbsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.thumbsKey) }
    }

    private var thumbsDir: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.thumbDir)
    }

    init() {}

    // MARK: - Fetch from Supabase

    func fetch() async {
        guard let uid = currentUserID else {
            await MainActor.run { debugMessage = "FETCH: no currentUserID" }
            return
        }
        await MainActor.run { debugMessage = "Fetching for \(uid.uuidString.prefix(8))…" }
        do {
            let rows: [TapestryRow] = try await supabase
                .from("tapestries")
                .select()
                .eq("owner_id", value: uid.uuidString)
                .order("updated_at", ascending: false)
                .execute()
                .value

            await MainActor.run {
                let thumbMap = savedThumbnailMap
                tapestries = rows.map { row in
                    var t = row.toTapestry()
                    t.thumbnailFilename = thumbMap[row.id.uuidString]
                    return t
                }
                debugMessage = "Fetched \(rows.count) tapestries ✓"
            }
        } catch {
            await MainActor.run { debugMessage = "FETCH ERROR: \(error)" }
            print("TapestryStore.fetch error: \(error)")
        }
    }

    // MARK: - CRUD

    func add(_ tapestry: Tapestry) {
        tapestries.insert(tapestry, at: 0)   // optimistic local update — newest first
        guard let uid = currentUserID else { return }
        Task {
            do {
                try await supabase
                    .from("tapestries")
                    .insert(TapestryInsert(
                        id: tapestry.id,
                        ownerID: uid,
                        title: tapestry.title,
                        description: tapestry.description,
                        type: tapestry.type.rawValue
                    ))
                    .execute()
            } catch {
                await MainActor.run { debugMessage = "INSERT ERROR: \(error)" }
                print("TapestryStore.add error: \(error)")
            }
        }
    }

    func clear() {
        tapestries = []
    }

    func updateCanvas(tapestryID: UUID, canvasJSON: String) {
        let now = Date()
        // Immediate local update + re-sort so most-recently-edited bubble moves first
        if let i = tapestries.firstIndex(where: { $0.id == tapestryID }) {
            tapestries[i].canvasData = canvasJSON
            tapestries[i].updatedAt  = now
        }

        Task {
            do {
                struct CanvasUpdate: Encodable {
                    let canvas_data: String
                    let updated_at:  String
                }
                try await supabase
                    .from("tapestries")
                    .update(CanvasUpdate(canvas_data: canvasJSON,
                                        updated_at: TapestryRow.isoFull.string(from: now)))
                    .eq("id", value: tapestryID.uuidString)
                    .execute()
            } catch {
                print("TapestryStore.updateCanvas error: \(error)")
            }
        }
    }

    func delete(_ tapestry: Tapestry) {
        tapestries.removeAll { $0.id == tapestry.id }
        thumbnailCache.removeValue(forKey: tapestry.id)
        viewportCache.removeValue(forKey: tapestry.id)
        // Remove local thumbnail
        if let fn = tapestry.thumbnailFilename {
            try? FileManager.default.removeItem(at: thumbsDir.appendingPathComponent(fn))
        }
        var map = savedThumbnailMap
        map.removeValue(forKey: tapestry.id.uuidString)
        savedThumbnailMap = map
        Task {
            do {
                try await supabase
                    .from("tapestries")
                    .delete()
                    .eq("id", value: tapestry.id.uuidString)
                    .execute()
            } catch {
                print("TapestryStore.delete error: \(error)")
            }
        }
    }

    // MARK: - Thumbnail helpers (local disk, Storage upload coming later)

    func saveThumbnail(_ image: UIImage, for tapestryID: UUID) -> String? {
        thumbnailCache[tapestryID] = image          // cache immediately in memory
        let dir = thumbsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "\(tapestryID.uuidString).jpg"
        guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
        let url = dir.appendingPathComponent(filename)
        try? data.write(to: url)
        return filename
    }

    func thumbnail(for tapestry: Tapestry) -> UIImage? {
        // Serve from memory cache — zero disk I/O on subsequent calls
        if let cached = thumbnailCache[tapestry.id] { return cached }
        guard let fn = tapestry.thumbnailFilename else { return nil }
        let url = thumbsDir.appendingPathComponent(fn)
        let img = UIImage(contentsOfFile: url.path)
        if let img { thumbnailCache[tapestry.id] = img }   // populate cache for next time
        return img
    }

    func updateThumbnailFilename(tapestryID: UUID, filename: String) {
        if let i = tapestries.firstIndex(where: { $0.id == tapestryID }) {
            tapestries[i].thumbnailFilename = filename
        }
        var map = savedThumbnailMap
        map[tapestryID.uuidString] = filename
        savedThumbnailMap = map
    }

    // MARK: - Canvas Mode (per-tapestry, set at creation time)

    private static let canvasModesKey = "tapestry_canvas_modes"
    @ObservationIgnored private var canvasModeCache: [UUID: CanvasMode] = [:]

    func canvasMode(for tapestryID: UUID) -> CanvasMode {
        if let cached = canvasModeCache[tapestryID] { return cached }
        guard let data = UserDefaults.standard.data(forKey: Self.canvasModesKey),
              let map  = try? JSONDecoder().decode([String: String].self, from: data),
              let raw  = map[tapestryID.uuidString],
              let mode = CanvasMode(rawValue: raw) else { return .infinite }
        canvasModeCache[tapestryID] = mode
        return mode
    }

    func setCanvasMode(tapestryID: UUID, mode: CanvasMode) {
        canvasModeCache[tapestryID] = mode
        var map: [String: String] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.canvasModesKey),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            map = existing
        }
        map[tapestryID.uuidString] = mode.rawValue
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: Self.canvasModesKey)
        }
    }

    // MARK: - Viewport adjustments (how the thumbnail is framed in the bubble)

    private static let viewportsKey = "tapestry_viewports"

    private struct ViewportRecord: Codable {
        var offsetX: Double
        var offsetY: Double
        var scale:   Double
    }

    func viewport(for tapestryID: UUID) -> (offset: CGSize, scale: CGFloat) {
        // Serve from memory — avoids UserDefaults + JSON decode on every render
        if let cached = viewportCache[tapestryID] { return cached }
        guard let data = UserDefaults.standard.data(forKey: Self.viewportsKey),
              let map  = try? JSONDecoder().decode([String: ViewportRecord].self, from: data),
              let v    = map[tapestryID.uuidString] else {
            return (.zero, 1.0)
        }
        let result = (CGSize(width: v.offsetX, height: v.offsetY), CGFloat(v.scale))
        viewportCache[tapestryID] = result
        return result
    }

    func setViewport(tapestryID: UUID, offset: CGSize, scale: CGFloat) {
        viewportCache[tapestryID] = (offset, scale)   // update memory cache immediately
        var map: [String: ViewportRecord] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.viewportsKey),
           let existing = try? JSONDecoder().decode([String: ViewportRecord].self, from: data) {
            map = existing
        }
        map[tapestryID.uuidString] = ViewportRecord(
            offsetX: Double(offset.width),
            offsetY: Double(offset.height),
            scale:   Double(scale)
        )
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: Self.viewportsKey)
        }
    }
}
