import SwiftUI
import PhotosUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ─────────────────────────────────────────────────────────────────────────────


private func initials(from name: String) -> String {
    let words = name.split(separator: " ").filter { !$0.isEmpty }
    switch words.count {
    case 0:  return "?"
    case 1:  return String(words[0].prefix(1)).uppercased()
    default: return (String(words.first!.prefix(1)) + String(words.last!.prefix(1))).uppercased()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ProfileView
// ─────────────────────────────────────────────────────────────────────────────

struct ProfileView: View {

    @Environment(TapestryStore.self) private var store
    @Environment(AuthManager.self)   private var auth
    @Environment(\.colorScheme)      private var colorScheme

    @AppStorage("profile_name")        private var profileName:        String = ""
    @AppStorage("profile_bio")         private var profileBio:         String = ""
    @AppStorage("profile_pronouns")    private var profilePronouns:    String = ""
    @AppStorage("profile_has_photo")   private var hasPhoto:           Bool   = false
    @AppStorage("profile_avatar_url")  private var profileAvatarURL:   String = ""
    private var pinnedTapestry: Tapestry? { store.pinnedTapestry }

    private var unpinnedTapestries: [Tapestry] {
        store.orderedUnpinnedTapestries(excludingPinnedID: pinnedTapestry?.id)
    }

    // Profile avatar
    @State private var profilePhotoData:   Data?             = nil
    @State private var selectedAvatarItem: PhotosPickerItem? = nil

    private var avatarURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile_photo.jpg")
    }

    // Navigation / modals
    @State private var showSettings:       Bool          = false
    @State private var createType:         TapestryType? = nil
    @State private var showTypePopup:      Bool          = false
    @State private var showJoinView:       Bool          = false
    @State private var openTapestry:       Tapestry?     = nil
    @State private var entryFlash:         Bool          = false

    @State private var coverPickTapestry:   Tapestry?     = nil
    @State private var coverPickAspectRatio: CGFloat      = 1.0
    @State private var tapestryToDelete:    Tapestry?     = nil
    @State private var tapestryToLeave:     Tapestry?     = nil

    private var displayName: String {
        profileName.trimmingCharacters(in: .whitespaces).isEmpty ? "Your Name" : profileName
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Body
    // ─────────────────────────────────────────────────────────────────────────

    var body: some View {
        ZStack {
            // ── Main scroll ──────────────────────────────────────────────────
            NavigationStack {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        profileHeader
                        if let pinned = pinnedTapestry { pinnedCard(pinned) }
                        if !unpinnedTapestries.isEmpty {
                            TapestryGridView(
                                tapestries: unpinnedTapestries,
                                onPin: { store.setPinned(tapestryID: $0) },
                                coverPickTapestry: $coverPickTapestry,
                                coverPickAspectRatio: $coverPickAspectRatio,
                                onSelect: enterTapestry
                            )
                        }
                        Spacer().frame(height: 100) // room for FAB
                    }
                }
                .scrollDisabled(false)
                .navigationBarHidden(true)
                .safeAreaInset(edge: .top, spacing: 0) { topBar }
                .sheet(isPresented: $showSettings) {
                    ProfileSettingsView().environment(auth)
                }
                .onChange(of: showSettings) { _, open in
                    if !open {
                        if let d = try? Data(contentsOf: avatarURL) {
                            profilePhotoData = d
                        } else if !profileAvatarURL.isEmpty,
                                  let url = URL(string: profileAvatarURL) {
                            Task {
                                if let (data, resp) = try? await URLSession.shared.data(from: url),
                                   let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                                    try? data.write(to: avatarURL)
                                    await MainActor.run {
                                        profilePhotoData = data
                                        hasPhoto = true
                                    }
                                }
                            }
                        }
                    }
                }
                .sheet(item: $createType) { type in
                    CreateTapestryView(tapestryType: type, onCreated: { tapestry in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            enterTapestry(tapestry)
                        }
                    })
                    .environment(store)
                }
                .sheet(isPresented: $showJoinView) {
                    JoinTapestryView(onJoined: { joined in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            enterTapestry(joined)
                        }
                    })
                    .environment(store)
                    .environment(auth)
                }
                .fullScreenCover(item: $coverPickTapestry) { tapestry in
                    NavigationStack {
                        StickerCanvasView(
                            tapestryID: tapestry.id,
                            initialCanvasData: tapestry.canvasData,
                            canvasMode: store.canvasMode(for: tapestry.id),
                            coverPickerMode: true,
                            coverFrameAspectRatio: coverPickAspectRatio,
                            onCoverPicked: { _ in coverPickTapestry = nil },
                            onCoverCancelled: { coverPickTapestry = nil }
                        )
                        .navigationTitle("Edit Cover")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                    }
                    .environment(store)
                }
                .confirmationDialog(
                    tapestryToDelete.map { "Delete \"\($0.title)\"?" } ?? "",
                    isPresented: Binding(
                        get: { tapestryToDelete != nil },
                        set: { if !$0 { tapestryToDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let t = tapestryToDelete { withAnimation { store.delete(t) } }
                        tapestryToDelete = nil
                    }
                    Button("Cancel", role: .cancel) { tapestryToDelete = nil }
                }
                .alert(
                    "Remove from your profile?",
                    isPresented: Binding(
                        get: { tapestryToLeave != nil },
                        set: { if !$0 { tapestryToLeave = nil } }
                    ),
                    presenting: tapestryToLeave
                ) { tapestry in
                    Button("Remove", role: .destructive) {
                        withAnimation { store.leaveTapestry(tapestry) }
                        tapestryToLeave = nil
                    }
                    Button("Cancel", role: .cancel) { tapestryToLeave = nil }
                } message: { tapestry in
                    Text("This removes \"\(tapestry.title)\" from your profile. Other members will still have access.")
                }
                .onAppear { loadAvatarPhoto() }
                .onChange(of: profileAvatarURL) { _, _ in loadAvatarPhoto() }
                .onTapGesture {
                    if showTypePopup {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            showTypePopup = false
                        }
                    }
                }
            }

            // ── FAB: create tapestry ─────────────────────────────────────────
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    if showTypePopup {
                        typePopup
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            showTypePopup.toggle()
                        }
                    } label: {
                        ZStack {
                            Circle().fill(Color.black).frame(width: 60, height: 60)
                                .overlay(Circle().strokeBorder(.white.opacity(colorScheme == .dark ? 0.45 : 0), lineWidth: 1.5))
                                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)
                            Image(systemName: showTypePopup ? "xmark" : "plus")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                                .animation(.spring(response: 0.3), value: showTypePopup)
                        }
                    }
                    .padding(.bottom, 96)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .zIndex(10)

            // ── Entry flash ─────────────────────────────────────────────────
            if entryFlash {
                Color.white.ignoresSafeArea().zIndex(90)
            }

            // ── Full-screen tapestry ─────────────────────────────────────────
            if let t = openTapestry {
                TapestryDetailView(tapestry: t, onDismiss: { openTapestry = nil })
                    .zIndex(80)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Top bar
    // ─────────────────────────────────────────────────────────────────────────

    private var topBar: some View {
        HStack {
            Text("TAPESTRY")
                .font(.custom("Avenir-Light", size: 18))
                .tracking(3)
                .foregroundStyle(.primary)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .medium))
            }
            .tint(.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background {
            LinearGradient(
                colors: [Color(.systemBackground), Color(.systemBackground),
                         Color(.systemBackground).opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Profile header
    // ─────────────────────────────────────────────────────────────────────────

    private var profileHeader: some View {
        VStack(spacing: 8) {
            // Avatar
            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                Group {
                    if let d = profilePhotoData, let img = UIImage(data: d) {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: 110, height: 110).clipShape(Circle())
                    } else {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color(red: 0.4, green: 0.6, blue: 1.0),
                                         Color(red: 0.6, green: 0.4, blue: 1.0)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 110, height: 110)
                            .overlay(
                                Text(initials(from: profileName))
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                            )
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
            }
            .onChange(of: selectedAvatarItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            profilePhotoData = data
                            try? data.write(to: avatarURL)
                            hasPhoto = true
                        }
                    }
                }
            }

            // Hidden pronouns on the left balance the visible ones on the right,
            // so the name's center stays at screen center.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !profilePronouns.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(profilePronouns)
                        .font(.system(size: 13))
                        .hidden()
                }
                Text(displayName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.primary)
                if !profilePronouns.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(profilePronouns)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)

            // Bio
            if !profileBio.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(profileBio)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Stats row
            HStack(spacing: 0) {
                statItem(value: 0, label: "Followers")
                Divider().frame(height: 14).padding(.horizontal, 10)
                statItem(value: 0, label: "Following")
                Divider().frame(height: 14).padding(.horizontal, 10)
                statItem(value: store.tapestries.count, label: "Tapestries")
            }
            .padding(.vertical, 6)

            // Edit Profile button
            Button("Edit Profile") { showSettings = true }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 36).padding(.vertical, 10)
                .background(Color(UIColor.systemGray5))
                .clipShape(Capsule())
        }
        .padding(.top, 12)
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

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Pinned tapestry card
    // ─────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private func pinnedCard(_ tapestry: Tapestry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PINNED")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1.5)
                .padding(.horizontal, 20)

            ZStack(alignment: .bottomLeading) {
                Group {
                    if let img = store.thumbnail(for: tapestry) {
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
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipped()

                // Pin badge
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
            .onTapGesture { enterTapestry(tapestry) }
            .contextMenu {
                Button {
                    let screenWidth = UIScreen.main.bounds.width - 32
                    coverPickAspectRatio = screenWidth / 200
                    coverPickTapestry = tapestry
                } label: {
                    Label("Edit Cover", systemImage: "crop")
                }
                Button {
                    withAnimation { store.setPinned(tapestryID: nil) }
                } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
                if tapestry.ownerID == store.currentUserID {
                    Button(role: .destructive) {
                        tapestryToDelete = tapestry
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } else {
                    Button(role: .destructive) {
                        tapestryToLeave = tapestry
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Type popup
    // ─────────────────────────────────────────────────────────────────────────

    private var typePopup: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation { showTypePopup = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    createType = .personal
                }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.blue.opacity(0.12)).frame(width: 40, height: 40)
                        Image(systemName: "person.fill")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Personal Tapestry")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                        Text("Just for you")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 72)

            Button {
                withAnimation { showTypePopup = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    createType = .group
                }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.purple.opacity(0.12)).frame(width: 40, height: 40)
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.purple)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Group Tapestry")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                        Text("Shared canvas")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 72)

            Button {
                withAnimation { showTypePopup = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    showJoinView = true
                }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.green.opacity(0.12)).frame(width: 40, height: 40)
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Join Tapestry")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                        Text("Enter an invite code")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
        .padding(.horizontal, 24)
        .onTapGesture { } // prevents taps propagating to background dismissal
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Helpers
    // ─────────────────────────────────────────────────────────────────────────


    private func enterTapestry(_ t: Tapestry) {
        withAnimation(.easeIn(duration: 0.16)) { entryFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            openTapestry = t
            withAnimation(.easeOut(duration: 0.20)) { entryFlash = false }
        }
    }

    private func loadAvatarPhoto() {
        if let d = try? Data(contentsOf: avatarURL) {
            profilePhotoData = d
        } else if !profileAvatarURL.isEmpty, let url = URL(string: profileAvatarURL) {
            Task {
                if let (data, resp) = try? await URLSession.shared.data(from: url),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    try? data.write(to: avatarURL)
                    await MainActor.run {
                        profilePhotoData = data
                        hasPhoto = true
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    ProfileView()
        .environment(TapestryStore())
        .environment(AuthManager())
}
