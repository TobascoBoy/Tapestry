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
    @AppStorage("profile_has_photo")   private var hasPhoto:           Bool   = false
    @AppStorage("pinned_tapestry_id")  private var pinnedTapestryIDStr: String = ""

    private var pinnedTapestry: Tapestry? {
        guard !pinnedTapestryIDStr.isEmpty,
              let id = UUID(uuidString: pinnedTapestryIDStr)
        else { return nil }
        return store.tapestries.first { $0.id == id }
    }

    private var unpinnedTapestries: [Tapestry] {
        store.orderedUnpinnedTapestries(excludingPinnedID: pinnedTapestry?.id)
    }

    /// During a drag, returns tapestries in the live preview order; otherwise the stored order.
    private var displayedTapestries: [Tapestry] {
        guard draggingID != nil, !previewOrder.isEmpty else { return unpinnedTapestries }
        let byID = Dictionary(uniqueKeysWithValues: unpinnedTapestries.map { ($0.id, $0) })
        return previewOrder.compactMap { byID[$0] }
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
    @State private var tapestryToDelete:   Tapestry?     = nil
    @State private var tapestryToLeave:    Tapestry?     = nil
    @State private var coverPickTapestry:  Tapestry?     = nil
    @State private var coverPickAspectRatio: CGFloat     = 1.0

    // Reorder state
    @State private var isReordering  = false
    @State private var draggingID:   UUID?   = nil
    @State private var previewOrder: [UUID]  = []

    // Layout-editing state (tap covers to cycle shape)
    @State private var isEditingLayout = false

    // Width of the grid (updated by GeometryReader inside the grid)
    @State private var gridWidth: CGFloat = UIScreen.main.bounds.width - 32

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
                        if !unpinnedTapestries.isEmpty { tapestryGrid }
                        Spacer().frame(height: 100) // room for FAB
                    }
                }
                .scrollDisabled(draggingID != nil)
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
                        if let t = tapestryToDelete {
                            withAnimation { store.delete(t) }
                        }
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
                    Text("This removes \"\(tapestry.title)\" from your profile. Other members will still have access and the tapestry will not be deleted.")
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
                                .overlay(Circle().strokeBorder(.white.opacity(colorScheme == .dark ? 0.45 : 0), lineWidth: 1.5))
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

            // Name
            Text(displayName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.primary)
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
                        let accent = bubbleAccent(for: tapestry)
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
                    withAnimation { pinnedTapestryIDStr = "" }
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
    // MARK: - 2-column tapestry grid
    // ─────────────────────────────────────────────────────────────────────────

    /// Describes how tapestries are grouped into visual rows.
    private enum LayoutSection: Identifiable {
        case wide(Tapestry)                           // spans full row
        case pair(Tapestry, Tapestry)                 // two squares side by side
        case single(Tapestry)                         // one square, left-aligned
        case tallLeft(Tapestry, [Tapestry])           // tall on left,  ≤2 squares on right
        case tallRight([Tapestry], Tapestry)          // ≤2 squares on left, tall on right

        var id: UUID {
            switch self {
            case .wide(let t):           return t.id
            case .pair(let t, _):        return t.id
            case .single(let t):         return t.id
            case .tallLeft(let t, _):    return t.id
            case .tallRight(let sq, _):  return sq[0].id
            }
        }
    }

    private func buildLayout(_ taps: [Tapestry]) -> [LayoutSection] {
        var result: [LayoutSection] = []
        var i = 0
        while i < taps.count {
            let t         = taps[i]
            let shape     = store.coverShape(for: t.id)
            let isDragged = draggingID == t.id

            switch shape {
            case .wide:
                result.append(.wide(t))
                i += 1

            case .tall:
                if isDragged {
                    // Dragged item always starts its own section so section.id
                    // stays stable throughout the drag → gesture isn't cancelled.
                    result.append(.tallLeft(t, []))
                    i += 1
                } else {
                    var right: [Tapestry] = []
                    var j = i + 1
                    while j < taps.count, right.count < 2,
                          store.coverShape(for: taps[j].id) == .square,
                          taps[j].id != draggingID {   // never consume the dragged item
                        right.append(taps[j])
                        j += 1
                    }
                    result.append(.tallLeft(t, right))
                    i = j
                }

            case .square:
                if isDragged {
                    result.append(.single(t))
                    i += 1
                } else if i + 1 < taps.count,
                          taps[i + 1].id != draggingID,
                          store.coverShape(for: taps[i + 1].id) == .tall {
                    // Square(s) on LEFT, tall on RIGHT.
                    let tall = taps[i + 1]
                    if i + 2 < taps.count,
                       taps[i + 2].id != draggingID,
                       store.coverShape(for: taps[i + 2].id) == .square {
                        result.append(.tallRight([t, taps[i + 2]], tall))
                        i += 3
                    } else {
                        result.append(.tallRight([t], tall))
                        i += 2
                    }
                } else if i + 1 < taps.count,
                          store.coverShape(for: taps[i + 1].id) == .square,
                          taps[i + 1].id != draggingID {
                    result.append(.pair(t, taps[i + 1]))
                    i += 2
                } else {
                    result.append(.single(t))
                    i += 1
                }
            }
        }
        return result
    }

    private var tapestryGrid: some View {
        let taps     = displayedTapestries
        let sections = buildLayout(taps)
        let cellW    = (gridWidth - 12) / 2
        // tallH must equal the combined height of two stacked square covers so the
        // left (tall) and right (2× square) columns are perfectly flush:
        //   right col = 2×(cellW + 6 + titleRowH) + 12
        //   left col  = tallH + 6 + titleRowH
        //   ⟹ tallH = 2×cellW + 18 + titleRowH  (titleRowH ≈ 18 → tallH = 2×cellW + 36)
        let titleRowH: CGFloat = 18
        let tallH    = cellW * 2 + 18 + titleRowH   // = cellW * 2 + 36
        return VStack(spacing: 0) {
            // Section header
            HStack {
                Text("TAPESTRIES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Spacer()
                if isEditingLayout {
                    Button("Done") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isEditingLayout = false
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
                } else if isReordering {
                    Button("Done") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if !previewOrder.isEmpty {
                                let byID = Dictionary(uniqueKeysWithValues: unpinnedTapestries.map { ($0.id, $0) })
                                let ordered = previewOrder.compactMap { byID[$0] }
                                store.setDisplayOrder(to: ordered)
                            }
                            isReordering = false
                            draggingID   = nil
                            previewOrder = []
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            VStack(spacing: 12) {
                ForEach(sections) { section in
                    layoutSectionView(section, cellW: cellW, tallH: tallH)
                }
            }
            .coordinateSpace(name: "tapestryGrid")
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { gridWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in gridWidth = w }
                }
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: previewOrder)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func layoutSectionView(_ section: LayoutSection, cellW: CGFloat, tallH: CGFloat) -> some View {
        switch section {
        case .wide(let t):
            gridCoverCell(t, width: gridWidth, height: cellW)
        case .pair(let t1, let t2):
            HStack(alignment: .top, spacing: 12) {
                gridCoverCell(t1, width: cellW, height: cellW)
                gridCoverCell(t2, width: cellW, height: cellW)
            }
        case .single(let t):
            HStack(spacing: 0) {
                gridCoverCell(t, width: cellW, height: cellW)
                Spacer()
            }
        case .tallLeft(let tall, let rights):
            HStack(alignment: .top, spacing: 12) {
                gridCoverCell(tall, width: cellW, height: tallH)
                VStack(spacing: 12) {
                    ForEach(rights) { t in
                        gridCoverCell(t, width: cellW, height: cellW)
                    }
                    if rights.count < 2 {
                        Color.clear.frame(width: cellW, height: rights.isEmpty ? tallH : cellW)
                    }
                }
                .frame(width: cellW, alignment: .top)
            }
        case .tallRight(let lefts, let tall):
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    ForEach(lefts) { t in
                        gridCoverCell(t, width: cellW, height: cellW)
                    }
                    if lefts.count < 2 {
                        Color.clear.frame(width: cellW, height: lefts.isEmpty ? tallH : cellW)
                    }
                }
                .frame(width: cellW, alignment: .top)
                gridCoverCell(tall, width: cellW, height: tallH)
            }
        }
    }

    @ViewBuilder
    private func gridCoverCell(_ tapestry: Tapestry, width: CGFloat, height: CGFloat) -> some View {
        let isDragging = draggingID == tapestry.id

        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let img = store.thumbnail(for: tapestry) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    let accent = bubbleAccent(for: tapestry)
                    LinearGradient(colors: [accent, accent.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: tapestry.type == .group ? "person.3.fill" : "photo.artframe")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(width: width, height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isReordering {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.38))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .padding(6)
                }
            }
            .overlay {
                if isEditingLayout { shapeEditOverlay(for: tapestry) }
            }
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)

            HStack(spacing: 4) {
                Text(tapestry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if tapestry.type == .group {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .scaleEffect(isDragging ? 0.94 : 1.0)
        .opacity(isDragging ? 0.55 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isDragging)
        .onTapGesture {
            if isEditingLayout {
                cycleShape(for: tapestry)
            } else if !isReordering {
                enterTapestry(tapestry)
            }
        }
        .contextMenu {
            Button {
                let cellW = (gridWidth - 12) / 2
                let shape = store.coverShape(for: tapestry.id)
                coverPickAspectRatio = switch shape {
                case .square: 1.0
                case .wide:   gridWidth / cellW
                case .tall:   cellW / (cellW * 2 + 36)
                }
                coverPickTapestry = tapestry
            } label: {
                Label("Edit Cover", systemImage: "crop")
            }
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isEditingLayout = true
                    isReordering    = false
                    draggingID      = nil
                    previewOrder    = []
                }
            } label: {
                Label("Edit Layout", systemImage: "square.grid.2x2")
            }
            Button {
                withAnimation { pinnedTapestryIDStr = tapestry.id.uuidString }
            } label: {
                Label("Pin to Profile", systemImage: "pin")
            }
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    previewOrder    = unpinnedTapestries.map(\.id)
                    isReordering    = true
                    isEditingLayout = false
                }
            } label: {
                Label("Move", systemImage: "arrow.up.arrow.down")
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
        .gesture(
            isReordering
            ? DragGesture(minimumDistance: 6, coordinateSpace: .named("tapestryGrid"))
                .onChanged { value in
                    if draggingID != tapestry.id {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        draggingID = tapestry.id
                        if previewOrder.isEmpty {
                            previewOrder = unpinnedTapestries.map(\.id)
                        }
                    }
                    let targetIdx = gridTargetIndex(at: value.location, taps: displayedTapestries)
                    guard let fromIdx = previewOrder.firstIndex(of: tapestry.id),
                          targetIdx != fromIdx else { return }
                    var newOrder = previewOrder
                    newOrder.remove(at: fromIdx)
                    newOrder.insert(tapestry.id, at: targetIdx)
                    previewOrder = newOrder
                }
                .onEnded { _ in
                    let byID = Dictionary(uniqueKeysWithValues: unpinnedTapestries.map { ($0.id, $0) })
                    let ordered = previewOrder.compactMap { byID[$0] }
                    if !ordered.isEmpty { store.setDisplayOrder(to: ordered) }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        draggingID = nil
                    }
                }
            : nil
        )
    }

    /// Dimmed overlay showing the current shape, tappable to cycle to next shape.
    @ViewBuilder
    private func shapeEditOverlay(for tapestry: Tapestry) -> some View {
        let shape = store.coverShape(for: tapestry.id)
        ZStack {
            Color.black.opacity(0.28)
            VStack {
                Spacer()
                Label(shape.label, systemImage: shape.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func cycleShape(for tapestry: Tapestry) {
        let next = store.coverShape(for: tapestry.id).next
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.setCoverShape(tapestryID: tapestry.id, shape: next)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Grid drag helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Maps a drag location to a target array index using the actual cell positions
    /// in the current mixed (square / wide / tall) layout.
    private func gridTargetIndex(at location: CGPoint, taps: [Tapestry]) -> Int {
        guard !taps.isEmpty else { return 0 }
        let cellW     = (gridWidth - 12) / 2
        let gap: CGFloat    = 12
        let titleH: CGFloat = 18          // must match titleRowH used in tapestryGrid
        let cellTotalH = cellW + 6 + titleH   // cover + VStack spacing + title

        // Build a list of (array index → visual center) for every cell.
        var centers: [(idx: Int, center: CGPoint)] = []
        var y: CGFloat = 0
        var i = 0

        while i < taps.count {
            let t         = taps[i]
            let shape     = store.coverShape(for: t.id)
            let isDragged = draggingID == t.id

            switch shape {
            case .wide:
                centers.append((i, CGPoint(x: gridWidth / 2, y: y + cellTotalH / 2)))
                y += cellTotalH + gap
                i += 1

            case .tall:
                let tallCoverH = cellW * 2 + 18 + titleH   // = cellW*2+36, matches tapestryGrid
                let tallTotalH = tallCoverH + 6 + titleH
                centers.append((i, CGPoint(x: cellW / 2, y: y + tallTotalH / 2)))
                var rightY = y
                var j = i + 1
                var rightCount = 0
                let maxRight = isDragged ? 0 : 2
                while j < taps.count, rightCount < maxRight,
                      store.coverShape(for: taps[j].id) == .square,
                      taps[j].id != draggingID {
                    centers.append((j, CGPoint(x: cellW + gap + cellW / 2,
                                               y: rightY + cellTotalH / 2)))
                    rightY += cellTotalH + gap
                    j += 1; rightCount += 1
                }
                y += max(tallTotalH, rightCount > 0 ? rightY - y - gap : tallTotalH) + gap
                i = j

            case .square:
                let tallCoverH2 = cellW * 2 + 18 + titleH
                let tallTotalH2 = tallCoverH2 + 6 + titleH
                if isDragged {
                    centers.append((i, CGPoint(x: cellW / 2, y: y + cellTotalH / 2)))
                    y += cellTotalH + gap
                    i += 1
                } else if i + 1 < taps.count,
                          taps[i + 1].id != draggingID,
                          store.coverShape(for: taps[i + 1].id) == .tall {
                    // tallRight: square(s) left, tall right
                    centers.append((i, CGPoint(x: cellW / 2, y: y + cellTotalH / 2)))
                    centers.append((i + 1, CGPoint(x: cellW + gap + cellW / 2,
                                                   y: y + tallTotalH2 / 2)))
                    if i + 2 < taps.count,
                       taps[i + 2].id != draggingID,
                       store.coverShape(for: taps[i + 2].id) == .square {
                        centers.append((i + 2, CGPoint(x: cellW / 2,
                                                       y: y + cellTotalH + gap + cellTotalH / 2)))
                        y += max(tallTotalH2, 2 * cellTotalH + gap) + gap
                        i += 3
                    } else {
                        y += max(tallTotalH2, cellTotalH) + gap
                        i += 2
                    }
                } else if i + 1 < taps.count,
                          store.coverShape(for: taps[i + 1].id) == .square,
                          taps[i + 1].id != draggingID {
                    centers.append((i,     CGPoint(x: cellW / 2,               y: y + cellTotalH / 2)))
                    centers.append((i + 1, CGPoint(x: cellW + gap + cellW / 2, y: y + cellTotalH / 2)))
                    y += cellTotalH + gap
                    i += 2
                } else {
                    centers.append((i, CGPoint(x: cellW / 2, y: y + cellTotalH / 2)))
                    y += cellTotalH + gap
                    i += 1
                }
            }
        }

        // Return the array index whose cell center is closest to the drag location.
        var bestIdx  = 0
        var bestDist = CGFloat.infinity
        for (arrayIdx, center) in centers {
            let dx = location.x - center.x
            let dy = location.y - center.y
            let d  = dx * dx + dy * dy
            if d < bestDist { bestDist = d; bestIdx = arrayIdx }
        }
        return min(max(0, taps.count - 1), bestIdx)
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
