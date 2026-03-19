import Foundation
import Supabase
import AuthenticationServices
import CryptoKit

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

    // MARK: - Sign in with Apple

    private(set) var appleSignInNonce: String?

    func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    func prepareAppleSignIn() -> String {
        let nonce = randomNonce()
        appleSignInNonce = nonce
        return sha256(nonce)
    }

    @MainActor
    func handleAppleSignIn(credential: ASAuthorizationAppleIDCredential) async throws {
        guard let nonce = appleSignInNonce,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthError.missingCredentials
        }
        try await supabase.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    // MARK: - Deep link handling

    @MainActor
    func handle(url: URL) async {
        try? await supabase.auth.session(from: url)
        // authStateChanges listener in init() automatically picks up the new session
    }

    enum AuthError: LocalizedError {
        case missingCredentials
        var errorDescription: String? { "Sign in with Apple failed. Please try again." }
    }
}
