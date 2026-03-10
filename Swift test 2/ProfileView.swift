import SwiftUI
import PhotosUI

// MARK: - Scroll offset preference key

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Initials helper

private func initials(from name: String) -> String {
    let words = name.split(separator: " ").filter { !$0.isEmpty }
    switch words.count {
    case 0:  return "?"
    case 1:  return String(words[0].prefix(1)).uppercased()
    default: return (String(words.first!.prefix(1)) + String(words.last!.prefix(1))).uppercased()
    }
}

// MARK: - Profile View

struct ProfileView: View {
    @Environment(TapestryStore.self) private var store
    @Environment(AuthManager.self)   private var auth

    @AppStorage("profile_name")      private var profileName: String = ""
    @AppStorage("profile_bio")       private var profileBio:  String = ""
    @AppStorage("profile_has_photo") private var hasPhoto:    Bool   = false

    @State private var showCreate    = false
    @State private var showTypePopup = false
    @State private var showSettings  = false

    // Profile photo
    @State private var profilePhotoData: Data?          = nil
    @State private var selectedPhoto: PhotosPickerItem? = nil

    private var photoURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile_photo.jpg")
    }

    // In-place bubble expansion
    @State private var expandingID: UUID?        = nil

    // Delete confirmation
    @State private var tapestryToDelete: Tapestry? = nil

    // Cover picker — open canvas in framing mode
    @State private var coverPickerTapestry: Tapestry? = nil

    // Full-screen tapestry presentation (ZStack, no slide animation)
    @State private var openTapestry: Tapestry?   = nil
    @State private var entryFlash:   Bool        = false

    // Expanded scale: visually 300 pt from the 180 pt base
    private let expandedScale: CGFloat = 300.0 / 180.0
    private let cardWidth:     CGFloat = 180

    private var displayName: String {
        profileName.trimmingCharacters(in: .whitespaces).isEmpty ? "Your Name" : profileName
    }

    var body: some View {
        ZStack {
            // ── Main profile screen ──────────────────────────────────────────
            NavigationStack {
                ZStack(alignment: .bottom) {
                    Color(.systemBackground).ignoresSafeArea()

                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {

                            // MARK: Profile Header
                            VStack(spacing: 14) {
                                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                    Group {
                                            if let data = profilePhotoData, let uiImage = UIImage(data: data) {
                                                Image(uiImage: uiImage)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 110, height: 110)
                                                    .clipShape(Circle())
                                            } else {
                                                Circle()
                                                    .fill(LinearGradient(
                                                        colors: [Color(red: 0.4, green: 0.6, blue: 1.0),
                                                                 Color(red: 0.6, green: 0.4, blue: 1.0)],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    ))
                                                    .frame(width: 110, height: 110)
                                                    .overlay(
                                                        Text(initials(from: profileName))
                                                            .font(.system(size: 36, weight: .bold, design: .rounded))
                                                            .foregroundStyle(.white)
                                                    )
                                            }
                                        }
                                        // Colorful layered glow
                                        .shadow(color: Color(red: 0.5, green: 0.3, blue: 1.0).opacity(0.55), radius: 24, x: 0, y: 8)
                                        .shadow(color: Color(red: 0.3, green: 0.5, blue: 1.0).opacity(0.35), radius: 40, x: 0, y: 14)
                                        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
                                }
                                .onChange(of: selectedPhoto) { _, newItem in
                                    Task {
                                        if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                            profilePhotoData = data
                                            try? data.write(to: photoURL)
                                            hasPhoto = true
                                        }
                                    }
                                }

                                profileTextBlock
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                            // MARK: Tapestry Carousel
                            if store.personal.isEmpty {
                                emptyState(
                                    icon: "rectangle.stack.fill",
                                    message: "No tapestries yet.\nTap + to create your first one."
                                )
                            } else {
                                BubbleCarouselView(
                                    expandingID: $expandingID,
                                    tapestryToDelete: $tapestryToDelete
                                )
                            }

                            // MARK: Group Tapestries
                            sectionHeader("Group Tapestries")
                                .padding(.top, 48)
                            emptyState(
                                icon: "person.3.fill",
                                message: "Group Tapestries coming soon.\nCollaboration features are in the works!"
                            )

                            Spacer(minLength: 100)
                        }
                    }
                    // Collapse expanded bubble when tapping background
                    .onTapGesture {
                        if expandingID != nil {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                expandingID = nil
                            }
                        } else if showTypePopup {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                showTypePopup = false
                            }
                        }
                    }

                    // MARK: FAB
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
                                Circle()
                                    .fill(Color.black)
                                    .frame(width: 60, height: 60)
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
                .navigationBarHidden(true)
                .safeAreaInset(edge: .top, spacing: 0) {
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
                        // Feathered fade — opaque at top, transparent at bottom
                        LinearGradient(
                            colors: [
                                Color(.systemBackground),
                                Color(.systemBackground),
                                Color(.systemBackground).opacity(0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    }
                }
                .sheet(isPresented: $showSettings) {
                    ProfileSettingsView()
                        .environment(auth)
                }
                .onAppear {
                    if hasPhoto, let data = try? Data(contentsOf: photoURL) {
                        profilePhotoData = data
                    }
                }
                // Reload photo when settings sheet closes (user may have changed it)
                .onChange(of: showSettings) { _, isShowing in
                    if !isShowing, hasPhoto, let data = try? Data(contentsOf: photoURL) {
                        profilePhotoData = data
                    }
                }
                .sheet(isPresented: $showCreate) {
                    CreateTapestryView()
                        .environment(store)
                }
                // Cover picker sheet — canvas opens in framing mode
                .fullScreenCover(item: $coverPickerTapestry) { tapestry in
                    let mode = store.canvasMode(for: tapestry.id)
                    NavigationStack {
                        StickerCanvasView(
                            tapestryID: tapestry.id,
                            initialCanvasData: tapestry.canvasData,
                            canvasMode: mode,
                            coverPickerMode: true,
                            onCoverPicked: { _ in
                                coverPickerTapestry = nil
                                expandingID = nil
                            },
                            onCoverCancelled: {
                                coverPickerTapestry = nil
                            }
                        )
                        .navigationTitle(tapestry.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                    }
                    .environment(store)
                }
            }

            // ── Expanded bubble overlay — centered on screen ─────────────────
            if let expandedID = expandingID,
               let expandedTapestry = store.personal.first(where: { $0.id == expandedID }) {

                let bubbleD: CGFloat = cardWidth * expandedScale   // 300 pt
                let ac = bubbleAccent(for: expandedTapestry)

                // Backdrop — tap to collapse
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            expandingID = nil
                        }
                    }
                    .zIndex(50)

                VStack(spacing: 28) {
                    // Bubble — tap to enter
                    ZStack {
                        Group {
                            if let img = store.thumbnail(for: expandedTapestry) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: bubbleD, height: bubbleD)
                                    .clipped()
                            } else {
                                LinearGradient(
                                    colors: [ac, ac.opacity(0.65)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                                .frame(width: bubbleD, height: bubbleD)
                            }
                        }
                        .mask {
                            RadialGradient(
                                stops: [
                                    .init(color: .black, location: 0.00),
                                    .init(color: .black, location: 0.72),
                                    .init(color: .clear,  location: 1.00),
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: bubbleD / 2
                            )
                        }

                        // Rim layers
                        Circle().stroke(ac.opacity(0.25), lineWidth: 36).blur(radius: 20)
                        Circle()
                            .strokeBorder(
                                AngularGradient(colors: [
                                    Color(red: 0.85, green: 0.50, blue: 1.00),
                                    Color(red: 0.40, green: 0.75, blue: 1.00),
                                    Color(red: 0.45, green: 1.00, blue: 0.80),
                                    Color(red: 0.90, green: 1.00, blue: 0.45),
                                    Color(red: 1.00, green: 0.38, blue: 0.62),
                                    Color(red: 0.85, green: 0.50, blue: 1.00),
                                ], center: .center),
                                lineWidth: 5
                            )
                            .opacity(0.55).blendMode(.screen)
                        Circle()
                            .strokeBorder(
                                RadialGradient(colors: [.clear, .black.opacity(0.22)],
                                               center: .center,
                                               startRadius: bubbleD * 0.40,
                                               endRadius: bubbleD / 2),
                                lineWidth: 30
                            )
                        Circle()
                            .strokeBorder(
                                LinearGradient(stops: [
                                    .init(color: .white.opacity(0.75), location: 0.00),
                                    .init(color: .white.opacity(0.25), location: 0.12),
                                    .init(color: .clear,               location: 0.30),
                                    .init(color: .clear,               location: 1.00),
                                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 2
                            )
                    }
                    .frame(width: bubbleD, height: bubbleD)
                    .shadow(color: ac.opacity(0.40), radius: 40, x: 0, y: 20)
                    .onTapGesture {
                        guard let current = store.personal.first(where: { $0.id == expandedID }) else { return }
                        enterTapestry(current)
                    }

                    // Set cover button
                    Button {
                        // Dismiss the overlay first so the full-screen cover
                        // can present cleanly from the NavigationStack.
                        let t = expandedTapestry
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            expandingID = nil
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            coverPickerTapestry = t
                        }
                    } label: {
                        Label("Set Cover", systemImage: "camera.viewfinder")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background {
                                Capsule().fill(.ultraThinMaterial)
                                Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                            }
                    }
                }
                .zIndex(51)
                .transition(.scale(scale: 0.75).combined(with: .opacity))
            }

            // ── Entry flash — cheap white screen that covers the handoff ────
            if entryFlash {
                Color.white.ignoresSafeArea()
                    .zIndex(90)
            }

            // ── Tapestry full-screen overlay — no slide, pure appear ────────
            if let t = openTapestry {
                TapestryDetailView(tapestry: t, onDismiss: { openTapestry = nil })
                    .zIndex(80)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Profile text block (isolated from PhotosPicker color environment)

    private var profileTextBlock: some View {
        VStack(spacing: 8) {
            // Glassy name pill — frosted glass backing lets background color bleed through
            Text(displayName)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background {
                    ZStack {
                        // Frosted glass layer
                        Capsule()
                            .fill(.ultraThinMaterial)
                        // Subtle color tint that echoes the avatar gradient
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.4, green: 0.6, blue: 1.0).opacity(0.18),
                                        Color(red: 0.6, green: 0.4, blue: 1.0).opacity(0.18)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        // Specular rim
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.55), .white.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                }
                .shadow(color: Color(red: 0.5, green: 0.3, blue: 1.0).opacity(0.20), radius: 12, x: 0, y: 4)

            if !profileBio.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(profileBio)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(UIColor.secondaryLabel))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Text("Edit Profile")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(UIColor.label))
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(Color(UIColor.systemGray5))
                .clipShape(Capsule())
                .padding(.top, 2)
                .onTapGesture { showSettings = true }
        }
    }

    // MARK: Entry transition

    private func bubbleAccent(for tapestry: Tapestry) -> Color {
        let palette: [Color] = [
            Color(red: 0.95, green: 0.60, blue: 0.55),
            Color(red: 0.55, green: 0.75, blue: 0.95),
            Color(red: 0.75, green: 0.90, blue: 0.65),
            Color(red: 0.95, green: 0.80, blue: 0.50),
            Color(red: 0.80, green: 0.65, blue: 0.95),
            Color(red: 0.55, green: 0.90, blue: 0.85),
            Color(red: 0.95, green: 0.70, blue: 0.85),
        ]
        return palette[abs(tapestry.title.hashValue) % palette.count]
    }

    private func enterTapestry(_ t: Tapestry) {
        // 1 — flash in (trivially cheap)
        withAnimation(.easeIn(duration: 0.16)) { entryFlash = true }
        // 2 — while flash covers screen: swap to tapestry view, reset bubble state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            openTapestry = t
            expandingID  = nil
            // 3 — flash out to reveal tapestry already in place
            withAnimation(.easeOut(duration: 0.20)) { entryFlash = false }
        }
    }

    // MARK: Type Selection Popup

    private var typePopup: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation { showTypePopup = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showCreate = true }
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
                        Text("Just for you").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 72)

            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.purple.opacity(0.12)).frame(width: 40, height: 40)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.purple)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group Tapestry")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                    Text("Coming soon").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("Soon")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.purple.opacity(0.6)).clipShape(Capsule())
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
        .padding(.horizontal, 24)
        .onTapGesture { }
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title2.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
    }

    private func emptyState(icon: String, message: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 20)
            Spacer()
        }
    }
}

// MARK: - Bubble Carousel View
// Owns scroll offset locally so ProfileView doesn't re-render on every scroll frame.

private struct BubbleCarouselView: View {
    @Environment(TapestryStore.self) private var store
    @Binding var expandingID:     UUID?
    @Binding var tapestryToDelete: Tapestry?

    @State private var scrollOffset:   CGFloat = 0
    @State private var containerWidth: CGFloat = 390

    private let cardWidth:   CGFloat = 180
    private let cardSpacing: CGFloat = 20
    private let leadingPad:  CGFloat = 28

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: cardSpacing) {
                    ForEach(store.personal, id: \.id) { tapestry in
                        let tapestryID   = tapestry.id
                        let isExpanded   = expandingID == tapestryID
                        let index        = store.personal.firstIndex(where: { $0.id == tapestryID }) ?? 0

                        let cardCenter    = leadingPad + CGFloat(index) * (cardWidth + cardSpacing) + cardWidth / 2
                        let visibleCenter = scrollOffset + containerWidth / 2
                        let norm          = max(-1, min(1, (cardCenter - visibleCenter) / (containerWidth / 2)))
                        let swayRotation  = expandingID == nil ? Double(norm) * 5.0  : 0.0
                        let swayLift      = expandingID == nil ? Double(abs(norm)) * 10.0 : 0.0

                        TapestryCardView(
                            tapestry: tapestry,
                            thumbnail: store.thumbnail(for: tapestry)
                        )
                        .id(tapestryID)
                        .frame(width: cardWidth, height: cardWidth)
                        .rotationEffect(.degrees(swayRotation))
                        .offset(y: swayLift)
                        .opacity(isExpanded ? 0 : (expandingID != nil ? 0.25 : 1.0))
                        .animation(.spring(response: 0.48, dampingFraction: 0.76), value: expandingID)
                        .onTapGesture {
                            let id = tapestryID
                            withAnimation(.spring(response: 0.48, dampingFraction: 0.76)) {
                                expandingID = id
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            tapestryToDelete = tapestry
                        }
                    }
                }
                .allowsHitTesting(expandingID == nil)
                .padding(.horizontal, leadingPad)
                .padding(.vertical, 20)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollOffsetKey.self,
                            value: -geo.frame(in: .named("carousel")).minX
                        )
                    }
                )
            }
            .coordinateSpace(name: "carousel")
            .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
            .scrollClipDisabled()
            .scrollDisabled(expandingID != nil)
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
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            store.delete(t)
                        }
                    }
                    tapestryToDelete = nil
                }
                Button("Cancel", role: .cancel) { tapestryToDelete = nil }
            }
        }
        .frame(height: 260)
        .padding(.bottom, -40)
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { containerWidth = geo.size.width }
            }
        )
    }
}

#Preview {
    ProfileView()
        .environment(TapestryStore())
        .environment(AuthManager())
}
