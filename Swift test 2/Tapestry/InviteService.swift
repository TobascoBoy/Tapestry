import Foundation
import Supabase

// MARK: - InviteError

enum InviteError: LocalizedError {
    case notFound
    case expired

    var errorDescription: String? {
        switch self {
        case .notFound: return "Invite code not found. Check the code and try again."
        case .expired:  return "This invite code has expired. Ask the owner to share a new one."
        }
    }
}

// MARK: - InviteService

struct InviteService {

    // MARK: - Private row types

    private struct InviteRow: Decodable {
        let tapestryID: UUID
        let expiresAt:  String?

        enum CodingKeys: String, CodingKey {
            case tapestryID = "tapestry_id"
            case expiresAt  = "expires_at"
        }
    }

    private struct InviteInsert: Encodable {
        let tapestryID: UUID
        let createdBy:  UUID
        let token:      String
        let expiresAt:  String

        enum CodingKeys: String, CodingKey {
            case tapestryID = "tapestry_id"
            case createdBy  = "created_by"
            case token
            case expiresAt  = "expires_at"
        }
    }

    private struct MemberInsert: Encodable {
        let tapestryID: UUID
        let userID:     UUID

        enum CodingKeys: String, CodingKey {
            case tapestryID = "tapestry_id"
            case userID     = "user_id"
        }
    }

    // MARK: - Generate / Reuse

    /// Returns the existing room code for a tapestry if it hasn't expired,
    /// otherwise generates a new 6-letter code valid for 30 days.
    /// The same code is shown every time the owner taps the invite button —
    /// any number of people can use it (Jackbox-style).
    static func getOrCreateCode(tapestryID: UUID, userID: UUID) async throws -> String {
        let fmt = isoFormatter()
        let now = Date()

        // Check for an existing non-expired code for this tapestry
        let existing: [InviteRow] = try await supabase
            .from("tapestry_invites")
            .select()
            .eq("tapestry_id", value: tapestryID.uuidString)
            .order("expires_at", ascending: false)
            .limit(1)
            .execute()
            .value

        if let row = existing.first {
            let isExpired = row.expiresAt.flatMap { fmt.date(from: $0) }.map { $0 < now } ?? false
            if !isExpired {
                // Reuse existing code — no need to generate a new one
                // (token is not returned by InviteRow; re-fetch with token field)
                let withToken: [[String: String]] = try await supabase
                    .from("tapestry_invites")
                    .select("token")
                    .eq("tapestry_id", value: tapestryID.uuidString)
                    .order("expires_at", ascending: false)
                    .limit(1)
                    .execute()
                    .value
                if let token = withToken.first?["token"] { return token }
            }
        }

        // Generate a new 6-letter room code (no I or O to avoid 1/0 confusion)
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let token   = String((0..<6).map { _ in letters.randomElement()! })
        let expires = fmt.string(from: now.addingTimeInterval(30 * 24 * 3600))

        try await supabase
            .from("tapestry_invites")
            .insert(InviteInsert(tapestryID: tapestryID, createdBy: userID,
                                 token: token, expiresAt: expires))
            .execute()
        return token
    }

    // MARK: - Redeem

    /// Validates the code and adds the user to tapestry_members.
    /// Multi-use: no "already used" check — anyone with the code can join up to the member limit.
    static func redeemInvite(token: String, userID: UUID) async throws -> UUID {
        let normalised = token.trimmingCharacters(in: .whitespaces).uppercased()
        let fmt = isoFormatter()

        struct InviteTokenRow: Decodable {
            let tapestryID: UUID
            let expiresAt:  String?
            enum CodingKeys: String, CodingKey {
                case tapestryID = "tapestry_id"
                case expiresAt  = "expires_at"
            }
        }

        let rows: [InviteTokenRow] = try await supabase
            .from("tapestry_invites")
            .select()
            .eq("token", value: normalised)
            .execute()
            .value

        guard let invite = rows.first else { throw InviteError.notFound }

        if let expiresStr = invite.expiresAt,
           let expires = fmt.date(from: expiresStr),
           expires < Date() {
            throw InviteError.expired
        }

        // Add to members. Ignore duplicate-key errors (user already a member);
        // propagate everything else so real failures surface in the UI.
        do {
            try await supabase
                .from("tapestry_members")
                .insert(MemberInsert(tapestryID: invite.tapestryID, userID: userID))
                .execute()
        } catch {
            let desc = error.localizedDescription.lowercased()
            let isDuplicate = desc.contains("duplicate") || desc.contains("23505") || desc.contains("unique")
            if !isDuplicate { throw error }
        }

        return invite.tapestryID
    }

    // MARK: - Helpers

    private static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}
