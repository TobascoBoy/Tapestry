import SwiftUI

// MARK: - AvatarCircle
//
// Reusable circle avatar — loads from a URL string or falls back to initials.

struct AvatarCircle: View {
    let urlString: String?
    let name: String
    var size: CGFloat = 110

    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.4, green: 0.6, blue: 1.0),
                                 Color(red: 0.6, green: 0.4, blue: 1.0)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size)
                    .overlay(
                        Text(initials(from: name))
                            .font(.system(size: size * 0.30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    )
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
        .task(id: urlString) {
            guard let str = urlString, !str.isEmpty, let url = URL(string: str) else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let loaded = UIImage(data: data) else { return }
            await MainActor.run { image = loaded }
        }
    }

    private func initials(from name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        switch words.count {
        case 0:  return "?"
        case 1:  return String(words[0].prefix(1)).uppercased()
        default: return (String(words.first!.prefix(1)) + String(words.last!.prefix(1))).uppercased()
        }
    }
}

// MARK: - SearchView

struct SearchView: View {

    @Environment(AuthManager.self)   private var auth
    @Environment(TapestryStore.self) private var store

    @State private var query       = ""
    @State private var service     = UserSearchService()
    @State private var searchTask: Task<Void, Never>? = nil
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            searchBar
            Divider().padding(.top, 10)
            resultBody
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Text("DISCOVER")
                .font(.custom("Avenir-Light", size: 18))
                .tracking(3)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 56)
        .padding(.bottom, 14)
        .background {
            LinearGradient(
                colors: [Color(.systemBackground), Color(.systemBackground),
                         Color(.systemBackground).opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search people…", text: $query)
                .font(.system(size: 16))
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { runSearch() }

            if !query.isEmpty {
                Button {
                    query = ""
                    service.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(.systemGray3))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            guard !newValue.trimmingCharacters(in: .whitespaces).isEmpty else {
                service.clear(); return
            }
            guard let uid = auth.userID else { return }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await service.search(query: newValue, excludingUserID: uid)
            }
        }
    }

    // MARK: - Result body

    @ViewBuilder
    private var resultBody: some View {
        if service.isLoading {
            Spacer()
            ProgressView()
            Spacer()
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty && service.results.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "person.slash")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No people found")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Search for people by name")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(service.results) { user in
                        NavigationLink(destination:
                            OtherUserProfileView(user: user)
                                .environment(store)
                                .environment(auth)
                        ) {
                            UserSearchRow(user: user)
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 76)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 100)
            }
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let uid = auth.userID else { return }
        searchTask = Task { await service.search(query: query, excludingUserID: uid) }
    }
}

// MARK: - UserSearchRow

private struct UserSearchRow: View {
    let user: UserSearchService.UserResult

    var body: some View {
        HStack(spacing: 14) {
            AvatarCircle(urlString: user.avatarURL, name: user.displayName, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(user.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let pronouns = user.pronouns,
                       !pronouns.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(pronouns)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let bio = user.bio, !bio.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(bio)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(.systemGray3))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
