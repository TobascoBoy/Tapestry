import Foundation
import Observation
import Supabase

// MARK: - PublicTapestryLoader

/// Loads another user's personal tapestries for display in OtherUserProfileView.
/// Reuses the existing Tapestry model — no new struct needed.
@Observable
final class PublicTapestryLoader {

    var tapestries: [Tapestry] = []
    var isLoading = false

    // MARK: - Load

    func load(for ownerID: UUID) async {
        await MainActor.run { isLoading = true }

        do {
            let rows: [TapestryRow] = try await supabase
                .from("tapestries")
                .select("id, owner_id, title, description, type, created_at, updated_at, canvas_data, canvas_mode, thumbnail_url, cover_shape, display_order, is_pinned")
                .eq("owner_id", value: ownerID.uuidString)
                .eq("type", value: "personal")
                .order("display_order", ascending: true)
                .execute()
                .value

            let mapped = rows.map { $0.toTapestry() }
            await MainActor.run { tapestries = mapped; isLoading = false }
        } catch {
            print("[PublicTapestryLoader] load error: \(error)")
            await MainActor.run { isLoading = false }
        }
    }

    // MARK: - Row shape (mirrors TapestryRow in TapestryStore)

    private struct TapestryRow: Decodable {
        let id: UUID
        let ownerID: UUID
        let title: String
        let description: String
        let type: String
        let createdAt: String
        let updatedAt: String
        let canvasData: String?
        let canvasMode: String?
        let thumbnailURL: String?
        let coverShape: String?
        let displayOrder: Int?
        let isPinned: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case ownerID      = "owner_id"
            case title
            case description
            case type
            case createdAt    = "created_at"
            case updatedAt    = "updated_at"
            case canvasData   = "canvas_data"
            case canvasMode   = "canvas_mode"
            case thumbnailURL = "thumbnail_url"
            case coverShape   = "cover_shape"
            case displayOrder = "display_order"
            case isPinned     = "is_pinned"
        }

        func toTapestry() -> Tapestry {
            Tapestry(
                id: id,
                title: title,
                description: description,
                thumbnailFilename: nil,
                thumbnailURL: thumbnailURL,
                createdAt: parseDate(createdAt),
                updatedAt: parseDate(updatedAt),
                type: TapestryType(rawValue: type) ?? .personal,
                canvasData: canvasData,
                ownerID: ownerID,
                canvasMode: canvasMode.flatMap { CanvasMode(rawValue: $0) } ?? .infinite,
                coverShape: coverShape.flatMap { CoverShape(rawValue: $0) } ?? .square,
                displayOrder: displayOrder ?? 0,
                isPinned: isPinned ?? false
            )
        }

        private static let isoFull: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private static let isoBasic: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        private func parseDate(_ string: String) -> Date {
            Self.isoFull.date(from: string) ?? Self.isoBasic.date(from: string) ?? Date()
        }
    }
}
