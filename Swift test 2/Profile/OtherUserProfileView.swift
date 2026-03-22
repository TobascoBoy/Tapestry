import SwiftUI

// MARK: - OtherUserProfileView

struct OtherUserProfileView: View {

    let user: UserSearchService.UserResult

    @Environment(TapestryStore.self) private var store
    @Environment(AuthManager.self)   private var auth

    @State private var loader     = PublicTapestryLoader()
    @State private var openTapestry: Tapestry? = nil

    // Dummy bindings required by TapestryGridView — not used in read-only context
    @State private var dummyCoverPick: Tapestry? = nil
    @State private var dummyAspect: CGFloat = 1.0

    private var pinnedTapestry: Tapestry? { loader.tapestries.first(where: { $0.isPinned }) }
    private var unpinnedTapestries: [Tapestry] { loader.tapestries.filter { !$0.isPinned } }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                profileHeader

                if loader.isLoading {
                    ProgressView()
                        .padding(.top, 48)
                } else {
                    if let pinned = pinnedTapestry { pinnedCard(pinned) }

                    if !unpinnedTapestries.isEmpty {
                        TapestryGridView(
                            tapestries: unpinnedTapestries,
                            coverPickTapestry: $dummyCoverPick,
                            coverPickAspectRatio: $dummyAspect,
                            onSelect: { openTapestry = $0 }
                        )
                    } else if !loader.isLoading {
                        VStack(spacing: 12) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No tapestries yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 48)
                    }
                }

                Spacer().frame(height: 40)
            }
        }
        .navigationTitle(user.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.load(for: user.id) }
        .fullScreenCover(item: $openTapestry) { tapestry in
            TapestryDetailView(
                tapestry: tapestry,
                isReadOnly: true,
                onDismiss: { openTapestry = nil }
            )
            .environment(store)
            .environment(auth)
        }
    }

    // MARK: - Header

    private var profileHeader: some View {
        VStack(spacing: 8) {
            AvatarCircle(urlString: user.avatarURL, name: user.displayName, size: 110)
                .padding(.top, 16)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let pronouns = user.pronouns, !pronouns.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(pronouns)
                        .font(.system(size: 13))
                        .hidden()
                }
                Text(user.displayName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.primary)
                if let pronouns = user.pronouns, !pronouns.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(pronouns)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)

            if let bio = user.bio, !bio.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(bio)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Stats row
            HStack(spacing: 0) {
                statItem(value: 0,                         label: "Followers")
                Divider().frame(height: 14).padding(.horizontal, 10)
                statItem(value: 0,                         label: "Following")
                Divider().frame(height: 14).padding(.horizontal, 10)
                statItem(value: loader.tapestries.count,   label: "Tapestries")
            }
            .padding(.vertical, 6)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    private func statItem(value: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pinned card

    @ViewBuilder
    private func pinnedCard(_ tapestry: Tapestry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PINNED")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1.5)
                .padding(.horizontal, 20)

            ZStack(alignment: .bottomLeading) {
                RemoteThumbnail(urlString: tapestry.thumbnailURL, tapestry: tapestry)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipped()

                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(tapestry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 5)
            .padding(.horizontal, 16)
            .onTapGesture { openTapestry = tapestry }
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }
}

// MARK: - RemoteThumbnail

/// Shows a tapestry thumbnail loaded from a remote URL.
/// Falls back to a gradient placeholder while loading or if no URL is set.
private struct RemoteThumbnail: View {
    let urlString: String?
    let tapestry: Tapestry

    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                let accent = tapestryAccentColor(for: tapestry)
                LinearGradient(colors: [accent, accent.opacity(0.7)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .task(id: urlString) {
            guard let str = urlString, !str.isEmpty, let url = URL(string: str) else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let loaded = UIImage(data: data) else { return }
            await MainActor.run { image = loaded }
        }
    }
}

