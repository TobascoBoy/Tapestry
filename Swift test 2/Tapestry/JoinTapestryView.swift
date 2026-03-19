import SwiftUI

// MARK: - JoinTapestryView

struct JoinTapestryView: View {
    @Environment(TapestryStore.self) private var store
    @Environment(AuthManager.self)   private var auth
    @Environment(\.dismiss)          private var dismiss

    var onJoined: ((Tapestry) -> Void)? = nil

    @State private var code      = ""
    @State private var isLoading = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.purple)
                }
                .padding(.top, 20)

                VStack(spacing: 8) {
                    Text("Join a Tapestry")
                        .font(.title2.bold())
                    Text("Enter the 6-letter invite code\nshared by a tapestry owner.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Code input
                TextField("XXXXXX", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 40)
                    .onChange(of: code) { _, v in
                        code = String(v.uppercased().filter { $0.isLetter }.prefix(6))
                        errorMsg = nil
                    }

                if let err = errorMsg {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
                        .multilineTextAlignment(.center)
                }

                // Join button
                Button {
                    Task { await joinTapestry() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Join")
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(code.count == 6 ? Color.accentColor : Color(.systemFill))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(code.count < 6 || isLoading)
                .padding(.horizontal, 40)

                Spacer()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func joinTapestry() async {
        guard let uid = auth.userID else { return }
        isLoading = true
        errorMsg  = nil
        do {
            let tapestryID = try await InviteService.redeemInvite(token: code, userID: uid)
            await store.fetch()
            // Dismiss first so the navigation stack is ready to open the tapestry
            dismiss()
            if let joined = store.tapestries.first(where: { $0.id == tapestryID }) {
                onJoined?(joined)
            }
        } catch {
            errorMsg = error.localizedDescription
        }
        isLoading = false
    }
}
