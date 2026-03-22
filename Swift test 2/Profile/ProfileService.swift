import Foundation
import UIKit
import Supabase

// MARK: - ProfileService
//
// Syncs profile data (name, bio, pronouns, avatar) between the local
// @AppStorage cache and the Supabase `users` table. Called on sign-in
// to restore data after a reinstall, and on every save in settings.

enum ProfileService {

    // MARK: - Row shapes

    private struct UserRow: Decodable {
        let displayName: String?
        let bio:         String?
        let pronouns:    String?
        let avatarURL:   String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case bio
            case pronouns
            case avatarURL   = "avatar_url"
        }
    }

    // MARK: - Fetch

    /// Pulls the user's profile from Supabase and writes it into UserDefaults
    /// (the backing store for @AppStorage). Call this right after sign-in.
    static func fetchAndCache(userID: UUID) async {
        do {
            let rows: [UserRow] = try await supabase
                .from("users")
                .select("display_name, bio, pronouns, avatar_url")
                .eq("id", value: userID.uuidString)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first else { return }

            await MainActor.run {
                if let name = row.displayName, !name.isEmpty {
                    UserDefaults.standard.set(name, forKey: "profile_name")
                }
                if let bio = row.bio {
                    UserDefaults.standard.set(bio, forKey: "profile_bio")
                }
                if let pronouns = row.pronouns {
                    UserDefaults.standard.set(pronouns, forKey: "profile_pronouns")
                }
                if let url = row.avatarURL {
                    UserDefaults.standard.set(url, forKey: "profile_avatar_url")
                }
            }

            // Download avatar to local disk if we have a URL
            if let urlString = row.avatarURL,
               let url = URL(string: urlString),
               let (data, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let localURL = localAvatarURL()
                try? data.write(to: localURL)
                await MainActor.run {
                    UserDefaults.standard.set(true, forKey: "profile_has_photo")
                }
            }
        } catch {
            print("[ProfileService] fetch error: \(error)")
        }
    }

    // MARK: - Save text fields

    static func saveText(userID: UUID, name: String, bio: String, pronouns: String) {
        Task(priority: .utility) {
            struct TextUpsert: Encodable {
                let id:           String
                let display_name: String
                let bio:          String
                let pronouns:     String
            }
            do {
                try await supabase
                    .from("users")
                    .upsert(TextUpsert(id: userID.uuidString,
                                      display_name: name,
                                      bio: bio,
                                      pronouns: pronouns))
                    .execute()
            } catch {
                print("[ProfileService] saveText error: \(error)")
            }
        }
    }

    // MARK: - Upload avatar

    /// Uploads the avatar image to Supabase Storage, updates users.avatar_url,
    /// and saves the URL to UserDefaults. Returns the public URL string.
    @discardableResult
    static func uploadAvatar(_ data: Data, userID: UUID) async -> String? {
        let path = "avatars/\(userID.uuidString).jpg"
        do {
            try await supabase.storage
                .from("sticker-assets")
                .upload(path, data: data,
                        options: .init(contentType: "image/jpeg", upsert: true))

            let url = try supabase.storage
                .from("sticker-assets")
                .getPublicURL(path: path)
                .absoluteString

            struct AvatarUpsert: Encodable { let id: String; let avatar_url: String }
            try await supabase
                .from("users")
                .upsert(AvatarUpsert(id: userID.uuidString, avatar_url: url))
                .execute()

            await MainActor.run {
                UserDefaults.standard.set(url, forKey: "profile_avatar_url")
            }
            return url
        } catch {
            print("[ProfileService] uploadAvatar error: \(error)")
            return nil
        }
    }

    // MARK: - Local avatar path

    static func localAvatarURL() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile_photo.jpg")
    }
}
