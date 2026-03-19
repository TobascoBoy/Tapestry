import SwiftUI

// MARK: - InviteShareSheet

/// Bottom sheet shown after generating an invite code.
/// Displays the code and a share button so the owner can send it.
struct InviteShareSheet: View {
    let token: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack {
                Text("Invite to Tapestry")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)

            // Code display
            VStack(spacing: 6) {
                Text("Share this code:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(token)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .foregroundStyle(.primary)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = token
                    withAnimation(.spring(response: 0.3)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy Code",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(copied ? Color.green.opacity(0.15) : Color(.secondarySystemBackground))
                        .foregroundStyle(copied ? .green : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                ShareLink(item: "Join my Tapestry! Enter this invite code in the app: \(token)") {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text("Valid for 30 days • Up to 8 members")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background(Color(.systemBackground))
    }
}
