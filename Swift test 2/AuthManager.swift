import Foundation
import Supabase

// MARK: - AuthManager

@Observable
final class AuthManager {

    private(set) var session: Session? = nil
    private(set) var isLoading = true

    var isSignedIn: Bool { session != nil }
    var userID: UUID?    { session.flatMap { UUID(uuidString: $0.user.id.uuidString) } }

    init() {
        Task {
            // Streams every auth state change for the lifetime of the app
            for await (_, session) in supabase.auth.authStateChanges {
                await MainActor.run {
                    self.session  = session
                    self.isLoading = false
                }
            }
        }
    }

    @MainActor
    func signUp(email: String, password: String) async throws {
        try await supabase.auth.signUp(email: email, password: password)
    }

    @MainActor
    func signIn(email: String, password: String) async throws {
        try await supabase.auth.signIn(email: email, password: password)
    }

    @MainActor
    func signOut() async throws {
        try await supabase.auth.signOut()
        session = nil
    }
}
