import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @Environment(AuthManager.self) private var auth

    @AppStorage("profile_name") private var profileName: String = ""

    @State private var email        = ""
    @State private var password     = ""
    @State private var fullName     = ""
    @State private var isSignUp     = false
    @State private var isLoading    = false
    @State private var errorMessage: String?
    @State private var showEmailForm = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo / title
                VStack(spacing: 8) {
                    Text("TAPESTRY")
                        .font(.custom("Avenir-Light", size: 38))
                        .tracking(6)
                    Text(isSignUp ? "Create an account" : "Welcome back")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)

                if showEmailForm {
                    // Email form
                    VStack(spacing: 12) {
                        if isSignUp {
                            TextField("Full Name", text: $fullName)
                                .textContentType(.name)
                                .autocorrectionDisabled()
                                .padding(14)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        SecureField("Password", text: $password)
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                    // Submit button
                    Button {
                        Task { await submit() }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black)
                                .frame(height: 52)
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text(isSignUp ? "Create Account" : "Sign In")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty || (isSignUp && fullName.trimmingCharacters(in: .whitespaces).isEmpty))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                    // Back button
                    Button {
                        withAnimation { showEmailForm = false; errorMessage = nil }
                    } label: {
                        Text("Back")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)

                } else {
                    // Choice buttons
                    VStack(spacing: 12) {
                        // Continue with Email
                        Button {
                            withAnimation { showEmailForm = true }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.black)
                                    .frame(height: 52)
                                Text(isSignUp ? "Sign up with Email" : "Sign in with Email")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 24)

                        // Sign in with Apple
                        SignInWithAppleButton(
                            onRequest: { request in
                                let hashedNonce = auth.prepareAppleSignIn()
                                request.requestedScopes = [.fullName, .email]
                                request.nonce = hashedNonce
                            },
                            onCompletion: { result in
                                Task {
                                    switch result {
                                    case .success(let authorization):
                                        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                                            do {
                                                try await auth.handleAppleSignIn(credential: credential)
                                            } catch {
                                                errorMessage = error.localizedDescription
                                            }
                                        }
                                    case .failure(let error):
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                        )
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 24)

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 28)
                        }
                    }
                    .transition(.opacity)
                }

                // Toggle sign in / sign up
                Button {
                    withAnimation {
                        isSignUp.toggle()
                        showEmailForm = false
                        errorMessage = nil
                    }
                } label: {
                    Text(isSignUp ? "Already have an account? Sign in" : "Don't have an account? Sign up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                Spacer()
            }
        }
    }

    private func submit() async {
        isLoading    = true
        errorMessage = nil
        do {
            if isSignUp {
                try await auth.signUp(email: email, password: password)
                if !fullName.trimmingCharacters(in: .whitespaces).isEmpty {
                    profileName = fullName.trimmingCharacters(in: .whitespaces)
                }
            } else {
                try await auth.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    AuthView()
        .environment(AuthManager())
}
