import SwiftUI

struct AuthView: View {
    @Environment(AuthManager.self) private var auth

    @AppStorage("profile_name") private var profileName: String = ""

    @State private var email        = ""
    @State private var password     = ""
    @State private var fullName     = ""
    @State private var isSignUp     = false
    @State private var isLoading    = false
    @State private var errorMessage: String?

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

                // Fields
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

                // Primary button
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
                .padding(.top, 20)

                // Toggle sign in / sign up
                Button {
                    withAnimation { isSignUp.toggle() }
                    errorMessage = nil
                } label: {
                    Text(isSignUp ? "Already have an account? Sign in" : "Don't have an account? Sign up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 16)

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
