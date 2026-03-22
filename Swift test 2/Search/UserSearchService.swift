import Foundation
import Observation
import Supabase

// MARK: - UserSearchService

@Observable
final class UserSearchService {

    // MARK: - Result type

    struct UserResult: Identifiable {
        let id: UUID
        let displayName: String
        let avatarURL: String?
        let bio: String?
        let pronouns: String?
    }

    // MARK: - State

    var results: [UserResult] = []
    var isLoading = false

    // MARK: - Search

    /// Queries the `users` table for display names matching `query`, excluding
    /// the signed-in user. Caller is responsible for debouncing.
    func search(query: String, excludingUserID: UUID) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            await MainActor.run { results = []; isLoading = false }
            return
        }

        await MainActor.run { isLoading = true }

        do {
            let rows: [UserRow] = try await supabase
                .from("users")
                .select("id, display_name, avatar_url, bio, pronouns")
                .ilike("display_name", value: "%\(trimmed)%")
                .neq("id", value: excludingUserID.uuidString)
                .limit(30)
                .execute()
                .value

            let mapped = rows.compactMap { row -> UserResult? in
                guard let idString = row.id,
                      let uuid = UUID(uuidString: idString) else { return nil }
                return UserResult(
                    id: uuid,
                    displayName: row.displayName ?? "Unknown",
                    avatarURL: row.avatarURL,
                    bio: row.bio,
                    pronouns: row.pronouns
                )
            }

            await MainActor.run { results = mapped; isLoading = false }
        } catch {
            print("[UserSearchService] search error: \(error)")
            await MainActor.run { isLoading = false }
        }
    }

    func clear() {
        results = []
        isLoading = false
    }

    // MARK: - Row shape

    private struct UserRow: Decodable {
        let id: String?
        let displayName: String?
        let avatarURL: String?
        let bio: String?
        let pronouns: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case avatarURL   = "avatar_url"
            case bio
            case pronouns
        }
    }
}
