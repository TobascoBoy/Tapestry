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

    @AppStorage("profile_name")      private var profileName: String = ""
    @AppStorage("profile_bio")       private var profileBio:  String = ""
    @AppStorage("profile_has_photo") private var hasPhoto:    Bool   = false

    // Profile avatar
    @State private var profilePhotoData:   Data?             = nil
    @State private var selectedAvatarItem: PhotosPickerItem? = nil

    private var avatarURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile_photo.jpg")
    }

    // Navigation / modals
    @State private var showSettings:     Bool          = false
    @State private var createType:       TapestryType? = nil   // non-nil = sheet open
    @State private var showTypePopup:    Bool          = false
    @State private var openTapestry:     Tapestry?     = nil
    @State private var entryFlash:       Bool          = false
    @State private var tapestryToDelete: Tapestry?     = nil

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
                        if !store.personal.isEmpty { personalSection }
                        if !store.group.isEmpty { groupSection }
                        Spacer().frame(height: 100) // room for FAB
                    }
                }
                .navigationBarHidden(true)
                .safeAreaInset(edge: .top, spacing: 0) { topBar }
                .sheet(isPresented: $showSettings) {
                    ProfileSettingsView().environment(auth)
                }
                .onChange(of: showSettings) { _, open in
                    if !open, hasPhoto, let d = try? Data(contentsOf: avatarURL) {
                        profilePhotoData = d
                    }
                }
                .sheet(item: $createType) { type in
                    CreateTapestryView(tapestryType: type).environment(store)
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
                        if let t = tapestryToDelete {
                            withAnimation { store.delete(t) }
                        }
                        tapestryToDelete = nil
                    }
                    Button("Cancel", role: .cancel) { tapestryToDelete = nil }
                }
                .onAppear { loadAvatarPhoto() }
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
                                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)
                            Image(systemName: showTypePopup ? "xmark" : "plus")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                                .animation(.spring(response: 0.3), value: showTypePopup)
                        }
                    }
                    .padding(.bottom, 32)
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
                    .transition(.opacity)
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
        VStack(spacing: 10) {
            // Avatar
            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                Group {
                    if let d = profilePhotoData, let img = UIImage(data: d) {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: 88, height: 88).clipShape(Circle())
                    } else {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color(red: 0.4, green: 0.6, blue: 1.0),
                                         Color(red: 0.6, green: 0.4, blue: 1.0)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 88, height: 88)
                            .overlay(
                                Text(initials(from: profileName))
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                            )
                    }
                }
                .shadow(color: Color(red: 0.5, green: 0.3, blue: 1.0).opacity(0.4),
                        radius: 16, x: 0, y: 6)
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

            // Name
            Text(displayName)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            // Bio
            if !profileBio.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(profileBio)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Edit Profile button
            Button("Edit Profile") { showSettings = true }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(UIColor.label))
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Color(UIColor.systemGray5))
                .clipShape(Capsule())
        }
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Group section (bubbles)
    // ─────────────────────────────────────────────────────────────────────────

    private var groupSection: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(store.group) { tapestry in
                        groupBubble(tapestry)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1 : 0.88)
                                    .opacity(phase.isIdentity ? 1 : 0.6)
                            }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollTargetBehavior(.viewAligned)

            Divider()
                .padding(.top, 8)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func groupBubble(_ tapestry: Tapestry) -> some View {
        let accent = bubbleAccent(for: tapestry)
        VStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 90, height: 90)
                .overlay {
                    if let img = store.thumbnail(for: tapestry) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)

            Text(tapestry.title)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 72)
                .multilineTextAlignment(.center)
        }
        .onTapGesture { enterTapestry(tapestry) }
        .onLongPressGesture(minimumDuration: 0.5) {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            tapestryToDelete = tapestry
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Personal section (rectangle cards)
    // ─────────────────────────────────────────────────────────────────────────

    private var personalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PERSONAL")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1.5)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(store.personal) { tapestry in
                        TapestryCardView(tapestry: tapestry, thumbnail: store.thumbnail(for: tapestry))
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1 : 0.92)
                                    .opacity(phase.isIdentity ? 1 : 0.65)
                            }
                            .onTapGesture { enterTapestry(tapestry) }
                            .onLongPressGesture(minimumDuration: 0.5) {
                                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                tapestryToDelete = tapestry
                            }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .scrollTargetBehavior(.viewAligned)
        }
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
            }
            .buttonStyle(.plain)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
        .padding(.horizontal, 24)
        .onTapGesture { }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static let accentPalette: [Color] = [
        Color(red: 0.95, green: 0.60, blue: 0.55),
        Color(red: 0.55, green: 0.75, blue: 0.95),
        Color(red: 0.75, green: 0.90, blue: 0.65),
        Color(red: 0.95, green: 0.80, blue: 0.50),
        Color(red: 0.80, green: 0.65, blue: 0.95),
        Color(red: 0.55, green: 0.90, blue: 0.85),
        Color(red: 0.95, green: 0.70, blue: 0.85),
    ]

    private func bubbleAccent(for tapestry: Tapestry) -> Color {
        let hash = abs(tapestry.title.hashValue)
        return Self.accentPalette[hash % Self.accentPalette.count]
    }

    private func enterTapestry(_ t: Tapestry) {
        withAnimation(.easeIn(duration: 0.16)) { entryFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            openTapestry = t
            withAnimation(.easeOut(duration: 0.20)) { entryFlash = false }
        }
    }

    private func loadAvatarPhoto() {
        if hasPhoto, let d = try? Data(contentsOf: avatarURL) { profilePhotoData = d }
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
