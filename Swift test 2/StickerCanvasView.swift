import SwiftUI
import PhotosUI
import UIKit

private let canvasSize: CGFloat = 2000

// URL needs to be Identifiable to use .sheet(item:)
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - Background Model

enum CanvasBackground {
    case color(UIColor)
    case image(UIImage)
}

// MARK: - StickerCanvasView

struct StickerCanvasView: View {
    var tapestryID: UUID? = nil
    var initialCanvasData: String? = nil
    var canvasMode: CanvasMode = .infinite
    var coverPickerMode: Bool = false
    var coverFrameAspectRatio: CGFloat = 1.0   // width / height of target cover shape
    var onCoverPicked: ((UIImage) -> Void)? = nil
    var onCoverCancelled: (() -> Void)? = nil
    var isCollaborative: Bool = false
    var isOwner: Bool = true
    var onDismiss: (() -> Void)? = nil

    @Environment(TapestryStore.self) private var store
    @Environment(AuthManager.self)   private var auth
    @Environment(\.colorScheme)      private var colorScheme
    @Environment(\.scenePhase)       private var scenePhase

    @State private var collabSession: TapestryCollabSession? = nil

    @State private var stickers: [Sticker] = []
    @State private var selectedStickerID: UUID?
    @State private var topZ: Double = 0
    @State private var canvasScale: CGFloat = 1.0
    @State private var canvasOffset: CGSize = .zero

    // Background
    @State private var canvasBackground: CanvasBackground = .color(.white)
    @State private var showBackgroundSheet = false
    @State private var bgPickerItem: PhotosPickerItem?  // background photo picker only
    @State private var selectedColor: Color = .white

    // Trash zone
    @State private var showTrashZone = false
    @State private var trashIsTargeted = false

    // Music search
    @State private var showMusicSearch = false

    // Video
    @State private var showVideoPicker  = false
    @State private var pendingVideoURL: URL? = nil

    // Camera button
    @State private var showCameraMenu    = false
    @State private var showCameraCapture = false

    // Long-press menu
    @State private var selectedItem: PhotosPickerItem?
    @State private var showPlusMenu = false
    @State private var showPhotosPicker = false

    // Text editor
    @State private var showTextEditor        = false
    @State private var textEditorContent:    TextStickerContent? = nil
    @State private var textEditorTargetID:   UUID?               = nil

    // Layers panel
    @State private var showLayersPanel = false

    // Invite
    @State private var isGeneratingInvite = false
    @State private var pendingInviteToken: String? = nil
    @State private var inviteError: String? = nil

    // Auto-save / collab
    @State private var uploadedURLs: [UUID: String] = [:]
    @State private var uploadedThumbnailURLs: [UUID: String] = [:]
    @State private var autosaveTask: Task<Void, Never>? = nil
    @State private var canvasLoaded = false
    @State private var showTapestryDeletedAlert = false

    // Undo
    @State private var undoStack: [CanvasSnapshot] = []

    // Canvas view reference for thumbnail capture
    @State private var canvasUIView: CanvasUIView?

    var body: some View {
        canvasWithPickerSheets
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    if !coverPickerMode && !showTrashZone { cameraButton }
                    Spacer()
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showLayersPanel.toggle() }
                    } label: {
                        Image(systemName: "square.3.layers.3d").font(.system(size: 17, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showPlusMenu = true }
                    } label: {
                        Image(systemName: "sparkle").font(.system(size: 17, weight: .semibold))
                    }
                }
                if isCollaborative && isOwner && !coverPickerMode {
                    ToolbarItem(placement: .topBarTrailing) { inviteButton }
                }
            }
            .sheet(isPresented: Binding(
                get: { pendingInviteToken != nil },
                set: { if !$0 { pendingInviteToken = nil } }
            )) {
                if let token = pendingInviteToken {
                    InviteShareSheet(token: token).presentationDetents([.height(320)])
                }
            }
            .onAppear { Task { await startCanvas() } }
            .onDisappear {
                autosaveTask?.cancel()
                autosaveTask = nil
                if let session = collabSession {
                    collabSession = nil
                    Task { await session.end() }
                }
                saveCanvasLocalBackup()   // synchronous — survives app kill
                saveCanvas()             // async Supabase upload
            }
            .onChange(of: stickers) { _, _ in
                saveCanvasLocalBackup()  // immediate local safety net
                scheduleAutosave()       // debounced Supabase write
            }
            .onChange(of: scenePhase) { _, phase in
                // App going to background — flush to Supabase immediately
                // because we may not get a chance to complete the debounced save.
                if phase == .background {
                    autosaveTask?.cancel()
                    autosaveTask = nil
                    saveCanvasLocalBackup()
                    saveCanvas()
                }
            }
            .alert("Tapestry Deleted", isPresented: $showTapestryDeletedAlert) {
                Button("OK") { onDismiss?() }
            } message: {
                Text("The owner has deleted this tapestry.")
            }
    }

    private var canvasWithPickerSheets: some View {
        canvasContent
            .photosPicker(isPresented: $showPhotosPicker, selection: $selectedItem, matching: .images)
            .sheet(isPresented: $showMusicSearch) {
                MusicSearchView(
                    onSelect: { track in addMusicSticker(track: track); showMusicSearch = false },
                    onCancel: { showMusicSearch = false }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showVideoPicker) {
                VideoPicker { url in pendingVideoURL = url; showVideoPicker = false }
            }
            .fullScreenCover(isPresented: $showCameraCapture) {
                CameraCapturePicker(
                    onCapture: { image in showCameraCapture = false; addStickerFromCapturedImage(image) },
                    onCancel: { showCameraCapture = false }
                ).ignoresSafeArea()
            }
            .sheet(item: $pendingVideoURL) { url in
                VideoProcessingView(
                    videoURL: url,
                    onComplete: { result in pendingVideoURL = nil; addVideoSticker(result: result) },
                    onCancel: { pendingVideoURL = nil }
                )
            }
            .sheet(isPresented: $showBackgroundSheet) { backgroundSheet }
            .onChange(of: selectedItem) { _, newItem in
                guard let newItem else { return }
                Task { await addStickerFromImage(from: newItem) }
            }
            .onChange(of: bgPickerItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadBackgroundImage(from: newItem) }
            }
            .overlay { if showPlusMenu { plusMenuOverlay } }
            .overlay(alignment: .leading) { if showLayersPanel { layersPanelOverlay } }
            .overlay { if showCameraMenu { cameraMenuOverlay } }
            .overlay { if showTextEditor { textEditorOverlay } }
    }

    private var canvasContent: some View {
        CanvasHostView(
            stickers: $stickers,
            selectedStickerID: $selectedStickerID,
            canvasScale: $canvasScale,
            canvasOffset: $canvasOffset,
            canvasBackground: canvasBackground,
            canvasMode: canvasMode,
            onTapEmpty: {
                selectedStickerID = nil
                if showLayersPanel {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showLayersPanel = false }
                }
            },
            onTapSticker: { id in
                selectedStickerID = id
                bringToFront(stickerID: id)
                if showLayersPanel {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showLayersPanel = false }
                }
            },
            onDragChanged: { screenPos in
                let h = UIScreen.main.bounds.height
                withAnimation(.spring(duration: 0.25)) {
                    showTrashZone   = screenPos.y > h - 220
                    trashIsTargeted = screenPos.y > h - 130
                }
            },
            onDragEnded: { screenPos, stickerID in
                if screenPos.y > UIScreen.main.bounds.height - 130 {
                    saveUndoState()
                    withAnimation(.spring(duration: 0.2)) {
                        stickers.removeAll { $0.id == stickerID }
                        if selectedStickerID == stickerID { selectedStickerID = nil }
                    }
                    collabSession.map { $0.broadcast($0.opDelete(stickerID: stickerID)) }
                } else if let session = collabSession,
                          let s = stickers.first(where: { $0.id == stickerID }) {
                    session.broadcast(session.opMove(stickerID: stickerID, x: s.position.x, y: s.position.y))
                }
                withAnimation(.spring(duration: 0.3)) { showTrashZone = false; trashIsTargeted = false }
            },
            onStickerGestureStart: { saveUndoState() },
            onStickerGestureEnded: { id in broadcastGestureEnded(stickerID: id) },
            onTextEdit: { id in
                guard let sticker = stickers.first(where: { $0.id == id }),
                      case .text(let content) = sticker.kind else { return }
                textEditorContent = content
                textEditorTargetID = id
                withAnimation { showTextEditor = true }
            },
            onPhotoReplaced: { id, img in broadcastPhotoReplaced(stickerID: id, image: img) },
            onViewReady: { view in canvasUIView = view }
        )
        .ignoresSafeArea()
        .background(ShakeDetector())
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in undo() }
        .overlay(alignment: .bottom) {
            if showTrashZone && !coverPickerMode {
                trashZone.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay { if coverPickerMode { coverPickerOverlay } }
    }

    private var cameraButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showCameraMenu = true }
        } label: {
            ZStack {
                Circle()
                    .stroke(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red], center: .center), lineWidth: 4)
                    .frame(width: 54, height: 54).blur(radius: 6).opacity(0.85)
                Circle().fill(Color.black).frame(width: 50, height: 50)
                    .overlay(Circle().strokeBorder(.white.opacity(colorScheme == .dark ? 0.5 : 0), lineWidth: 1.5))
                Image(systemName: "camera.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private var inviteButton: some View {
        Button {
            guard let uid = auth.userID, let tid = tapestryID else { return }
            isGeneratingInvite = true
            Task {
                do {
                    let token = try await InviteService.getOrCreateCode(tapestryID: tid, userID: uid)
                    await MainActor.run { pendingInviteToken = token; isGeneratingInvite = false }
                } catch {
                    print("[Invite] getOrCreateCode failed: \(error)")
                    await MainActor.run { inviteError = error.localizedDescription; isGeneratingInvite = false }
                }
            }
        } label: {
            if isGeneratingInvite {
                ProgressView().tint(.primary).frame(width: 24, height: 24)
            } else {
                Image(systemName: "person.badge.plus").font(.system(size: 17, weight: .semibold))
            }
        }
        .disabled(isGeneratingInvite)
        .alert("Couldn't generate invite", isPresented: Binding(
            get: { inviteError != nil },
            set: { if !$0 { inviteError = nil } }
        )) {
            Button("OK") { inviteError = nil }
        } message: {
            Text(inviteError ?? "")
        }
    }

    private var plusMenuOverlay: some View {
        PlusMenuOverlay(
            onSelect: { item in
                showPlusMenu = false
                switch item {
                case .photo:      showPhotosPicker   = true
                case .text:       textEditorContent = nil; textEditorTargetID = nil; withAnimation { showTextEditor = true }
                case .background: showBackgroundSheet = true
                case .music:      showMusicSearch    = true
                case .video:      showVideoPicker    = true
                case .camera:     showCameraCapture  = true
                }
            },
            onDismiss: { showPlusMenu = false }
        )
    }

    private var cameraMenuOverlay: some View {
        CameraMenuOverlay(
            onSelect: { item in
                showCameraMenu = false
                switch item {
                case .photo:  showPhotosPicker  = true
                case .video:  showVideoPicker   = true
                case .camera: showCameraCapture = true
                default: break
                }
            },
            onDismiss: { showCameraMenu = false }
        )
    }

    private var layersPanelOverlay: some View {
        LayersPanelView(
            stickers: stickers,
            onSelect: { id in selectedStickerID = id; bringToFront(stickerID: id) },
            onDismiss: { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showLayersPanel = false } },
            onReorder: { orderedIDs in
                saveUndoState()
                for (position, id) in orderedIDs.enumerated() {
                    if let idx = stickers.firstIndex(where: { $0.id == id }) {
                        let z = Double(orderedIDs.count - position)
                        stickers[idx].zIndex = z
                        collabSession.map { $0.broadcast($0.opReorder(stickerID: id, zIndex: z)) }
                    }
                }
            }
        )
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var textEditorOverlay: some View {
        TextEditorOverlay(
            initialContent: textEditorContent,
            onComplete: { content in
                withAnimation { showTextEditor = false }
                if let targetID = textEditorTargetID,
                   let idx = stickers.firstIndex(where: { $0.id == targetID }) {
                    saveUndoState()
                    stickers[idx].kind = .text(content)
                    canvasUIView?.invalidateStickerCache()
                    collabSession.map { $0.broadcast($0.opUpdateText(stickerID: targetID, content: content)) }
                } else {
                    saveUndoState()
                    topZ += 1
                    let sticker = Sticker(kind: .text(content), position: visibleCenter(), scale: 1.0, rotation: .zero, zIndex: topZ)
                    stickers.append(sticker)
                    selectedStickerID = sticker.id
                    if let session = collabSession {
                        var state = StickerState(id: sticker.id, type: "text",
                            x: sticker.position.x, y: sticker.position.y, scale: 1.0, rotationRadians: 0, zIndex: sticker.zIndex)
                        state.textString = content.text; state.fontIndex = content.fontIndex
                        state.colorIndex = content.colorIndex; state.textWrapWidth = Double(content.wrapWidth)
                        state.textAlignment = content.alignment; state.textBGStyle = content.bgStyle
                        session.broadcast(session.opAdd(sticker: state))
                    }
                }
                textEditorContent = nil; textEditorTargetID = nil
            },
            onCancel: {
                withAnimation { showTextEditor = false }
                textEditorContent = nil; textEditorTargetID = nil
            }
        )
        .transition(.opacity)
    }

    // MARK: - Canvas Persistence

    private func startCanvas() async {
        try? await Task.sleep(for: .milliseconds(50))
        await loadCanvas()
        guard isCollaborative, let tid = tapestryID, let uid = store.currentUserID else { return }
        let session = TapestryCollabSession(tapestryID: tid, senderID: uid)
        collabSession = session
        session.onOpReceived = { op in applyRemoteOp(op) }
        session.onTapestryDeleted = { showTapestryDeletedAlert = true }
        await session.start()
    }

    private func scheduleAutosave() {
        guard canvasLoaded, tapestryID != nil, !coverPickerMode else { return }
        // During collab, only the owner autosaves. Members rely on per-op broadcasts
        // for live sync — having multiple writers causes race conditions where one
        // user's snapshot overwrites another's. The owner is the single source of
        // truth for canvas_data; their save survives even if the app is force-killed.
        if collabSession != nil && !isOwner { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveCanvas()
        }
    }

    // MARK: - Local backup helpers

    private func localBackupURL(for tid: UUID) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(tid.uuidString)_canvas.json")
    }

    /// Writes the canvas layout to a local JSON file immediately (synchronous, no uploads).
    /// Acts as a safety net against app kills before the debounced Supabase write completes.
    private func saveCanvasLocalBackup() {
        guard let tid = tapestryID, canvasLoaded, !coverPickerMode else { return }
        if collabSession != nil && !isOwner { return }

        var bgState = CanvasState.BackgroundState(type: "color")
        switch canvasBackground {
        case .color(let c):
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            bgState.colorComponents = [r, g, b, a].map { Double($0) }
        case .image:
            bgState.type = "image"
            // imageURL will be set on a successful Supabase write; for now we rely
            // on the local file fallback that was saved when the image was added.
        }

        let stickerStates: [StickerState] = stickers.map { sticker in
            var s = StickerState(id: sticker.id, type: "", x: sticker.position.x, y: sticker.position.y,
                                 scale: sticker.scale, rotationRadians: sticker.rotation.radians, zIndex: sticker.zIndex)
            switch sticker.kind {
            case .photo(let img):
                s.type = "photo"
                s.imageFilename = img.images != nil ? "\(sticker.id.uuidString).gif" : "\(sticker.id.uuidString).png"
                s.imageURL = uploadedURLs[sticker.id]
            case .text(let c):
                s.type = "text"; s.textString = c.text; s.fontIndex = c.fontIndex
                s.colorIndex = c.colorIndex; s.textWrapWidth = Double(c.wrapWidth)
                s.textAlignment = c.alignment; s.textBGStyle = c.bgStyle
            case .music(let t):
                s.type = "music"; s.musicID = t.id; s.musicTitle = t.title
                s.musicArtist = t.artistName
                s.musicArtworkURLString = t.artworkURL?.absoluteString
                s.musicPreviewURLString = t.previewURL?.absoluteString
            case .video(_, _, let bgRemoved):
                s.type = "video"; s.bgRemoved = bgRemoved
                s.videoURL = uploadedURLs[sticker.id]
                s.videoThumbnailURL = uploadedThumbnailURLs[sticker.id]
            }
            return s
        }

        guard let data = try? JSONEncoder().encode(CanvasState(background: bgState, stickers: stickerStates)) else { return }
        try? data.write(to: localBackupURL(for: tid))
    }

    private func loadCanvas() async {
        // Pick the best source: prefer whichever of (Supabase, local backup) has more stickers.
        // This ensures edits survive app kills before the Supabase write completes.
        var sourceJSON: String? = initialCanvasData
        if let tid = tapestryID {
            let backupURL = localBackupURL(for: tid)
            if let backupData = try? Data(contentsOf: backupURL) {
                if let remoteJSON = sourceJSON,
                   let remoteData = remoteJSON.data(using: .utf8),
                   let remoteState = try? JSONDecoder().decode(CanvasState.self, from: remoteData),
                   let localState  = try? JSONDecoder().decode(CanvasState.self, from: backupData) {
                    // Prefer local backup when it has more stickers (Supabase missed recent edits)
                    if localState.stickers.count > remoteState.stickers.count {
                        sourceJSON = String(data: backupData, encoding: .utf8)
                    }
                } else if sourceJSON == nil {
                    // No remote data at all — use local backup unconditionally
                    sourceJSON = String(data: backupData, encoding: .utf8)
                }
            }
        }

        guard let json = sourceJSON,
              let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(CanvasState.self, from: data) else {
            await MainActor.run { canvasLoaded = true }
            return
        }

        switch state.background.type {
        case "image":
            if let urlString = state.background.imageURL,
               let localURL = try? await StickerAssetUploader.cachedLocalURL(for: urlString, ext: "png"),
               let img = UIImage(contentsOfFile: localURL.path) {
                await MainActor.run { canvasBackground = .image(img) }
            }
        default:
            if let c = state.background.colorComponents, c.count == 4 {
                await MainActor.run {
                    canvasBackground = .color(UIColor(red: c[0], green: c[1], blue: c[2], alpha: c[3]))
                }
            }
        }

        var loaded: [Sticker] = []
        await withTaskGroup(of: Sticker?.self) { group in
            for s in state.stickers {
                group.addTask {
                    let pos = CGPoint(x: s.x, y: s.y)
                    let rot = Angle(radians: s.rotationRadians)
                    switch s.type {
                    case "photo":
                        // Try Supabase URL first; fall back to local file if URL is
                        // missing (upload was interrupted) or the download fails.
                        let img: UIImage?
                        if let urlString = s.imageURL {
                            let ext = urlString.hasSuffix(".gif") ? "gif" : "png"
                            if let localURL = try? await StickerAssetUploader.cachedLocalURL(for: urlString, ext: ext) {
                                img = ext == "gif" ? UIImage.animatedGIF(from: localURL) : UIImage(contentsOfFile: localURL.path)
                                if img != nil { await MainActor.run { uploadedURLs[s.id] = urlString } }
                            } else if let fn = s.imageFilename {
                                img = StickerStorage.loadImage(filename: fn)
                            } else {
                                img = nil
                            }
                        } else if let fn = s.imageFilename {
                            img = StickerStorage.loadImage(filename: fn)
                        } else {
                            img = nil
                        }
                        guard let img else { return nil }
                        return Sticker(id: s.id, kind: .photo(img), position: pos, scale: s.scale, rotation: rot, zIndex: s.zIndex)
                    case "text":
                        guard let text = s.textString, let fi = s.fontIndex, let ci = s.colorIndex else { return nil }
                        let content = TextStickerContent(text: text, fontIndex: fi, colorIndex: ci,
                            wrapWidth: s.textWrapWidth.map { CGFloat($0) } ?? 900,
                            alignment: s.textAlignment ?? 1, bgStyle: s.textBGStyle ?? 1)
                        return Sticker(id: s.id, kind: .text(content), position: pos, scale: s.scale, rotation: rot, zIndex: s.zIndex)
                    case "music":
                        guard let mid = s.musicID, let title = s.musicTitle, let artist = s.musicArtist else { return nil }
                        let track = MusicTrack(id: mid, title: title, artistName: artist,
                            artworkURL: s.musicArtworkURLString.flatMap { URL(string: $0) },
                            previewURL: s.musicPreviewURLString.flatMap { URL(string: $0) })
                        return Sticker(id: s.id, kind: .music(track), position: pos, scale: s.scale, rotation: rot, zIndex: s.zIndex)
                    case "video":
                        guard let vURL = s.videoURL, let tURL = s.videoThumbnailURL,
                              let localVideoURL = try? await StickerAssetUploader.cachedLocalURL(for: vURL, ext: "mp4"),
                              let localThumbURL = try? await StickerAssetUploader.cachedLocalURL(for: tURL, ext: "png"),
                              let thumb = UIImage(contentsOfFile: localThumbURL.path) else { return nil }
                        await MainActor.run { uploadedURLs[s.id] = vURL; uploadedThumbnailURLs[s.id] = tURL }
                        return Sticker(id: s.id, kind: .video(videoURL: localVideoURL, thumbnail: thumb, bgRemoved: s.bgRemoved ?? false), position: pos, scale: s.scale, rotation: rot, zIndex: s.zIndex)
                    default: return nil
                    }
                }
            }
            for await sticker in group { if let sticker { loaded.append(sticker) } }
        }

        loaded.sort { $0.zIndex < $1.zIndex }
        await MainActor.run {
            stickers = loaded
            topZ = loaded.map { $0.zIndex }.max() ?? 0
            canvasLoaded = true
        }

        // Artwork images are not persisted — re-fetch from artworkURL for every music sticker.
        for sticker in loaded {
            guard case .music(let track) = sticker.kind, let artURL = track.artworkURL else { continue }
            let sid = sticker.id
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: artURL),
                      let img = UIImage(data: data) else { return }
                if let idx = stickers.firstIndex(where: { $0.id == sid }),
                   case .music(var t) = stickers[idx].kind {
                    t.artworkImage = img
                    stickers[idx].kind = .music(t)
                }
            }
        }
    }

    private func saveCanvas() {
        guard let tid = tapestryID, canvasLoaded, !coverPickerMode else { return }
        if isCollaborative && !isOwner { return }
        let stickerSnapshot    = stickers
        let backgroundSnapshot = canvasBackground
        let urlCacheSnapshot      = uploadedURLs
        let thumbURLCacheSnapshot = uploadedThumbnailURLs

        let hasMediaStickers = stickerSnapshot.contains {
            switch $0.kind { case .photo, .video: return true; default: return false }
        }
        if !hasMediaStickers {
            var immediateBG = CanvasState.BackgroundState(type: "color")
            if case .color(let c) = backgroundSnapshot {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                immediateBG.colorComponents = [r, g, b, a].map { Double($0) }
            }
            let immediateStates: [StickerState] = stickerSnapshot.compactMap { sticker in
                var s = StickerState(id: sticker.id, type: "", x: sticker.position.x, y: sticker.position.y,
                                     scale: sticker.scale, rotationRadians: sticker.rotation.radians, zIndex: sticker.zIndex)
                switch sticker.kind {
                case .text(let c):
                    s.type = "text"; s.textString = c.text; s.fontIndex = c.fontIndex
                    s.colorIndex = c.colorIndex; s.textWrapWidth = Double(c.wrapWidth)
                    s.textAlignment = c.alignment; s.textBGStyle = c.bgStyle; return s
                case .music(let t):
                    s.type = "music"; s.musicID = t.id; s.musicTitle = t.title
                    s.musicArtist = t.artistName
                    s.musicArtworkURLString = t.artworkURL?.absoluteString
                    s.musicPreviewURLString = t.previewURL?.absoluteString; return s
                default: return nil
                }
            }
            if let data = try? JSONEncoder().encode(CanvasState(background: immediateBG, stickers: immediateStates)),
               let json = String(data: data, encoding: .utf8) {
                store.updateCanvas(tapestryID: tid, canvasJSON: json)
            }
        }

        Task(priority: .utility) { [store] in
            var bgState = CanvasState.BackgroundState(type: "color")
            switch backgroundSnapshot {
            case .color(let c):
                bgState.type = "color"
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                bgState.colorComponents = [r, g, b, a].map { Double($0) }
            case .image(let img):
                bgState.type = "image"
                bgState.imageURL = try? await StickerAssetUploader.uploadBackground(img, tapestryID: tid)
            }

            var stickerStates: [StickerState] = []
            for sticker in stickerSnapshot {
                var s = StickerState(id: sticker.id, type: "", x: sticker.position.x, y: sticker.position.y,
                                     scale: sticker.scale, rotationRadians: sticker.rotation.radians, zIndex: sticker.zIndex)
                switch sticker.kind {
                case .photo(let img):
                    s.type = "photo"
                    // Always record the local filename so photos survive even if the
                    // Supabase upload is interrupted (e.g. app backgrounded on close).
                    s.imageFilename = img.images != nil
                        ? "\(sticker.id.uuidString).gif"
                        : "\(sticker.id.uuidString).png"
                    if let cached = urlCacheSnapshot[sticker.id] {
                        s.imageURL = cached
                    } else {
                        let url: String?
                        if img.images != nil {
                            url = try? await StickerAssetUploader.uploadGIF(stickerID: sticker.id)
                        } else {
                            url = try? await StickerAssetUploader.uploadImage(img, stickerID: sticker.id)
                        }
                        s.imageURL = url
                        if let url = url { await MainActor.run { uploadedURLs[sticker.id] = url } }
                    }
                case .text(let c):
                    s.type = "text"; s.textString = c.text; s.fontIndex = c.fontIndex
                    s.colorIndex = c.colorIndex; s.textWrapWidth = Double(c.wrapWidth)
                    s.textAlignment = c.alignment; s.textBGStyle = c.bgStyle
                case .music(let t):
                    s.type = "music"; s.musicID = t.id; s.musicTitle = t.title
                    s.musicArtist = t.artistName
                    s.musicArtworkURLString = t.artworkURL?.absoluteString
                    s.musicPreviewURLString = t.previewURL?.absoluteString
                case .video(let url, let thumb, let bgRemoved):
                    s.type = "video"; s.bgRemoved = bgRemoved
                    if let cached = urlCacheSnapshot[sticker.id] {
                        s.videoURL = cached
                        if let cachedThumb = thumbURLCacheSnapshot[sticker.id] {
                            s.videoThumbnailURL = cachedThumb
                        } else {
                            s.videoThumbnailURL = try? await StickerAssetUploader.uploadVideoThumbnail(thumb, stickerID: sticker.id)
                            if let tURL = s.videoThumbnailURL { await MainActor.run { uploadedThumbnailURLs[sticker.id] = tURL } }
                        }
                    } else {
                        s.videoURL = try? await StickerAssetUploader.uploadVideo(from: url, stickerID: sticker.id)
                        if let vURL = s.videoURL { await MainActor.run { uploadedURLs[sticker.id] = vURL } }
                        s.videoThumbnailURL = try? await StickerAssetUploader.uploadVideoThumbnail(thumb, stickerID: sticker.id)
                        if let tURL = s.videoThumbnailURL { await MainActor.run { uploadedThumbnailURLs[sticker.id] = tURL } }
                    }
                }
                // Don't write a video sticker to Supabase if thumbnail URL is missing — loadCanvas()
                // requires both URLs and would silently drop it. The next save cycle will retry.
                if s.type == "video" && s.videoThumbnailURL == nil { continue }
                stickerStates.append(s)
                if let data = try? JSONEncoder().encode(CanvasState(background: bgState, stickers: stickerStates)),
                   let json = String(data: data, encoding: .utf8) {
                    await MainActor.run { store.updateCanvas(tapestryID: tid, canvasJSON: json) }
                }
            }
        }
    }

    // MARK: - Collab: Apply Remote Ops

    private func applyRemoteOp(_ op: StickerOp) {
        switch op.type {
        case .move:
            guard let x = op.x, let y = op.y, let i = stickers.firstIndex(where: { $0.id == op.stickerID }) else { return }
            stickers[i].position = CGPoint(x: x, y: y)
        case .scale:
            guard let scale = op.scale, let i = stickers.firstIndex(where: { $0.id == op.stickerID }) else { return }
            stickers[i].scale = scale
        case .rotate:
            guard let radians = op.rotationRadians, let i = stickers.firstIndex(where: { $0.id == op.stickerID }) else { return }
            stickers[i].rotation = Angle(radians: radians)
        case .add:
            guard let state = op.sticker, !stickers.contains(where: { $0.id == op.stickerID }) else { return }
            Task { await applyRemoteAdd(state) }
        case .delete:
            withAnimation(.spring(duration: 0.2)) {
                stickers.removeAll { $0.id == op.stickerID }
                if selectedStickerID == op.stickerID { selectedStickerID = nil }
            }
        case .reorder:
            guard let zIndex = op.zIndex, let i = stickers.firstIndex(where: { $0.id == op.stickerID }) else { return }
            stickers[i].zIndex = zIndex
        case .updateText:
            guard let text = op.textString, let fi = op.fontIndex, let ci = op.colorIndex,
                  let i = stickers.firstIndex(where: { $0.id == op.stickerID }) else { return }
            let content = TextStickerContent(text: text, fontIndex: fi, colorIndex: ci,
                wrapWidth: op.textWrapWidth.map { CGFloat($0) } ?? 900,
                alignment: op.textAlignment ?? 1, bgStyle: op.textBGStyle ?? 1)
            stickers[i].kind = .text(content)
            canvasUIView?.invalidateStickerCache()
        case .updatePhoto:
            guard let urlString = op.imageURL, let i = stickers.firstIndex(where: { $0.id == op.stickerID }) else { return }
            Task {
                let ext = urlString.hasSuffix(".gif") ? "gif" : "png"
                guard let localURL = try? await StickerAssetUploader.cachedLocalURL(for: urlString, ext: ext),
                      let img = UIImage(contentsOfFile: localURL.path) else { return }
                uploadedURLs[op.stickerID] = urlString
                stickers[i].kind = .photo(img)
                canvasUIView?.invalidateStickerCache()
            }
        case .updateBackground:
            if let comps = op.bgColorComponents, comps.count == 4 {
                canvasBackground = .color(UIColor(red: comps[0], green: comps[1], blue: comps[2], alpha: comps[3]))
            } else if let urlString = op.imageURL {
                Task {
                    guard let localURL = try? await StickerAssetUploader.cachedLocalURL(for: urlString, ext: "jpg"),
                          let img = UIImage(contentsOfFile: localURL.path) else { return }
                    await MainActor.run { canvasBackground = .image(img) }
                }
            }
        }
    }

    private func applyRemoteAdd(_ state: StickerState) async {
        let pos = CGPoint(x: state.x, y: state.y)
        let rot = Angle(radians: state.rotationRadians)
        switch state.type {
        case "photo":
            guard let urlString = state.imageURL else { return }
            let ext = urlString.hasSuffix(".gif") ? "gif" : "png"
            guard let localURL = try? await StickerAssetUploader.cachedLocalURL(for: urlString, ext: ext) else { return }
            let img = ext == "gif" ? UIImage.animatedGIF(from: localURL) : UIImage(contentsOfFile: localURL.path)
            guard let img else { return }
            await MainActor.run {
                uploadedURLs[state.id] = urlString
                stickers.append(Sticker(id: state.id, kind: .photo(img), position: pos, scale: state.scale, rotation: rot, zIndex: state.zIndex))
            }
        case "text":
            guard let text = state.textString, let fi = state.fontIndex, let ci = state.colorIndex else { return }
            let content = TextStickerContent(text: text, fontIndex: fi, colorIndex: ci,
                wrapWidth: state.textWrapWidth.map { CGFloat($0) } ?? 900,
                alignment: state.textAlignment ?? 1, bgStyle: state.textBGStyle ?? 1)
            await MainActor.run {
                stickers.append(Sticker(id: state.id, kind: .text(content), position: pos, scale: state.scale, rotation: rot, zIndex: state.zIndex))
            }
        case "music":
            guard let mid = state.musicID, let title = state.musicTitle, let artist = state.musicArtist else { return }
            let track = MusicTrack(id: mid, title: title, artistName: artist,
                artworkURL: state.musicArtworkURLString.flatMap { URL(string: $0) },
                previewURL: state.musicPreviewURLString.flatMap { URL(string: $0) })
            let sid = state.id
            await MainActor.run {
                stickers.append(Sticker(id: sid, kind: .music(track), position: pos, scale: state.scale, rotation: rot, zIndex: state.zIndex))
            }
            if let artURL = track.artworkURL {
                Task {
                    guard let (data, _) = try? await URLSession.shared.data(from: artURL),
                          let img = UIImage(data: data) else { return }
                    if let idx = stickers.firstIndex(where: { $0.id == sid }),
                       case .music(var t) = stickers[idx].kind {
                        t.artworkImage = img
                        stickers[idx].kind = .music(t)
                    }
                }
            }
        case "video":
            guard let vURL = state.videoURL, let tURL = state.videoThumbnailURL,
                  let localVideoURL = try? await StickerAssetUploader.cachedLocalURL(for: vURL, ext: "mp4"),
                  let localThumbURL = try? await StickerAssetUploader.cachedLocalURL(for: tURL, ext: "png"),
                  let thumb = UIImage(contentsOfFile: localThumbURL.path) else { return }
            await MainActor.run {
                uploadedURLs[state.id] = vURL
                uploadedThumbnailURLs[state.id] = tURL
                stickers.append(Sticker(id: state.id, kind: .video(videoURL: localVideoURL, thumbnail: thumb, bgRemoved: state.bgRemoved ?? false), position: pos, scale: state.scale, rotation: rot, zIndex: state.zIndex))
            }
        default: break
        }
    }


    // MARK: - Collab: Broadcast Gesture End

    private func broadcastGestureEnded(stickerID: UUID) {
        guard let session = collabSession,
              let s = stickers.first(where: { $0.id == stickerID }) else { return }
        session.broadcast(session.opScale(stickerID: stickerID, scale: s.scale))
        session.broadcast(session.opRotate(stickerID: stickerID, radians: s.rotation.radians))
    }

    private func broadcastPhotoReplaced(stickerID: UUID, image: UIImage) {
        // Save the background-removed image to disk immediately, overwriting the original.
        // This ensures the local fallback (imageFilename) is always up-to-date even if
        // the Supabase upload hasn't completed yet (e.g. app killed right after removal).
        let fn = "\(stickerID.uuidString).png"
        Task.detached(priority: .utility) { StickerStorage.saveImage(image, filename: fn) }

        // Clear the stale URL immediately so saveCanvas() cannot snapshot an old
        // original-photo URL before the new cutout upload finishes.  This is the key
        // fix for the group-tapestry revert bug: for group tapestries the photo is
        // uploaded eagerly on add, so uploadedURLs[stickerID] holds the original URL
        // right up until this point.  Without the clear, a saveCanvas() triggered by
        // onChange(stickers) could snapshot that stale URL and persist it to canvas_data,
        // causing the cutout to revert to the original on next load.
        uploadedURLs.removeValue(forKey: stickerID)

        Task(priority: .utility) {
            // Use a fresh UUID as the storage path so the URL changes after background
            // removal. Reusing stickerID keeps the same path, and the receiver finds the
            // stale original in its local cache and never re-downloads the cutout.
            let uploadID = UUID()
            guard let url = try? await StickerAssetUploader.uploadImage(image, stickerID: uploadID) else { return }
            await MainActor.run {
                uploadedURLs[stickerID] = url
                collabSession.map { $0.broadcast($0.opUpdatePhoto(stickerID: stickerID, imageURL: url)) }
            }
        }
    }

    // MARK: - Background Sheet

    private var backgroundSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Color picker
                VStack(alignment: .leading, spacing: 10) {
                    Text("Color")
                        .font(.headline)
                    ColorPicker("Background color", selection: $selectedColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: selectedColor) { _, newColor in
                            let uiColor = UIColor(newColor)
                            canvasBackground = .color(uiColor)
                            if let session = collabSession {
                                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                                uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
                                session.broadcast(session.opUpdateBackground(colorComponents: [r, g, b, a]))
                            }
                        }

                    // Quick preset swatches
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                        ForEach(presetColors, id: \.self) { color in
                            Circle()
                                .fill(Color(uiColor: color))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                .onTapGesture {
                                    selectedColor = Color(uiColor: color)
                                    canvasBackground = .color(color)
                                    if let session = collabSession {
                                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                                        color.getRed(&r, green: &g, blue: &b, alpha: &a)
                                        session.broadcast(session.opUpdateBackground(colorComponents: [r, g, b, a]))
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal)

                Divider()

                // Photo background picker
                VStack(alignment: .leading, spacing: 10) {
                    Text("Photo")
                        .font(.headline)
                        .padding(.horizontal)
                    PhotosPicker(selection: $bgPickerItem, matching: .images) {
                        Label("Choose Background Photo", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal)
                    }
                }

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showBackgroundSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private let presetColors: [UIColor] = [
        .white, .black, .systemGray6, .systemGray,
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemTeal, .systemBlue, .systemIndigo, .systemPurple,
        .systemPink, UIColor(red: 0.95, green: 0.88, blue: 0.76, alpha: 1), // cream
        UIColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1),              // dark charcoal
        UIColor(red: 0.85, green: 0.95, blue: 0.88, alpha: 1),              // mint
    ]

    // MARK: - Trash Zone

    private var trashZone: some View {
        HStack(spacing: 12) {
            Image(systemName: trashIsTargeted ? "trash.fill" : "trash")
                .font(.system(size: trashIsTargeted ? 26 : 22, weight: .semibold))
                .foregroundStyle(trashIsTargeted ? .red : .white)
                .scaleEffect(trashIsTargeted ? 1.15 : 1.0)
                .animation(.spring(duration: 0.2), value: trashIsTargeted)
            Text("Release to delete")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(trashIsTargeted
                      ? Color.red.opacity(0.35)
                      : Color.black.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(trashIsTargeted ? Color.red.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    // MARK: - Cover Picker Overlay

    private var coverPickerOverlay: some View {
        // No .ignoresSafeArea() on the GeometryReader — geo.size must match CanvasUIView.bounds
        GeometryReader { geo in
            let ar     = coverFrameAspectRatio
            let frameW = min(geo.size.width, geo.size.height * ar)
            let frameH = frameW / ar
            let xInset = (geo.size.width  - frameW) / 2
            let yInset = (geo.size.height - frameH) / 2
            let frameRect = CGRect(x: xInset, y: yInset, width: frameW, height: frameH)

            ZStack(alignment: .top) {
                // ── Dimmed surround with cutout ──────────────────────────────
                CoverFrameMask(frameRect: frameRect, size: geo.size)
                    .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                // ── Frame border ─────────────────────────────────────────────
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                    .frame(width: frameW, height: frameH)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .allowsHitTesting(false)

                // ── Corner ticks ─────────────────────────────────────────────
                CornerTicks(rect: frameRect)
                    .stroke(.white, lineWidth: 3)
                    .allowsHitTesting(false)

                // ── Top banner ───────────────────────────────────────────────
                HStack {
                    Button { onCoverCancelled?() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                    Text("Frame your cover")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial.opacity(0.85))

                // ── Checkmark confirm ────────────────────────────────────────
                VStack {
                    Spacer()
                    Button {
                        guard let tid = tapestryID, let cv = canvasUIView else {
                            onCoverCancelled?()
                            return
                        }
                        // Compute capture rect in canvasUIView's own coordinate space
                        let ar = coverFrameAspectRatio
                        let capW = min(cv.bounds.width, cv.bounds.height * ar)
                        let capH = capW / ar
                        let captureRect = CGRect(
                            x: (cv.bounds.width  - capW) / 2,
                            y: (cv.bounds.height - capH) / 2,
                            width: capW, height: capH
                        )
                        guard let img = cv.renderViewportThumbnail(in: captureRect) else {
                            onCoverCancelled?()
                            return
                        }
                        if let filename = store.saveThumbnail(img, for: tid) {
                            store.updateThumbnailFilename(tapestryID: tid, filename: filename)
                        }
                        onCoverPicked?(img)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 64, height: 64)
                                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                            Image(systemName: "checkmark")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.black)
                        }
                    }
                    .padding(.bottom, 52)
                    .padding(.top, 20)
                }
            }
        }
    }

}

// ── Cover picker helper shapes ────────────────────────────────────────────────

/// Fills the full rect minus a square hole — creates the dimmed surround effect.
private struct CoverFrameMask: Shape {
    let frameRect: CGRect
    let size: CGSize

    func path(in _: CGRect) -> Path {
        var p = Path(CGRect(origin: .zero, size: size))
        p.addRoundedRect(in: frameRect, cornerRadii: .init(topLeading: 16, bottomLeading: 16, bottomTrailing: 16, topTrailing: 16))
        return p
    }
}

/// Draws short L-shaped ticks at the four corners of the capture frame.
private struct CornerTicks: Shape {
    let rect: CGRect
    let tickLen: CGFloat = 20

    func path(in _: CGRect) -> Path {
        var p = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (rect.origin,                           1,  1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1,  1),
            (CGPoint(x: rect.minX, y: rect.maxY),  1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (pt, dx, dy) in corners {
            p.move(to: CGPoint(x: pt.x + dx * tickLen, y: pt.y))
            p.addLine(to: pt)
            p.addLine(to: CGPoint(x: pt.x, y: pt.y + dy * tickLen))
        }
        return p
    }
}

extension StickerCanvasView {
    // MARK: - Sticker Management

    @MainActor
    private func addStickerFromImage(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }

        let stickerID = UUID()
        let uiImage: UIImage

        if data.isGIF, let animated = UIImage.animatedGIF(from: data) {
            uiImage = animated
            // Persist raw GIF bytes immediately so saveCanvas can reference them by ID
            let fn = "\(stickerID.uuidString).gif"
            Task.detached(priority: .utility) { StickerStorage.saveGIF(data, filename: fn) }
        } else {
            guard let img = UIImage(data: data)?.normalized() else { return }
            uiImage = img
            // Save to disk immediately so saveCanvas can reference it locally if the
            // Supabase upload is interrupted (e.g. app goes to background on close).
            let fn = "\(stickerID.uuidString).png"
            Task.detached(priority: .utility) { StickerStorage.saveImage(img, filename: fn) }
        }

        saveUndoState()
        topZ += 1
        let sticker = Sticker(
            id: stickerID,
            kind: .photo(uiImage),
            position: visibleCenter(),
            scale: 1.0,
            rotation: .zero,
            zIndex: topZ
        )
        stickers.append(sticker)
        selectedStickerID = sticker.id
        selectedItem = nil

        if let session = collabSession, tapestryID != nil {
            let pos = sticker.position; let z = sticker.zIndex; let img = uiImage
            Task(priority: .utility) {
                let url: String?
                if img.images != nil {
                    url = try? await StickerAssetUploader.uploadGIF(stickerID: stickerID)
                } else {
                    url = try? await StickerAssetUploader.uploadImage(img, stickerID: stickerID)
                }
                guard let url else { return }
                await MainActor.run { uploadedURLs[stickerID] = url }
                var state = StickerState(id: stickerID, type: "photo",
                    x: pos.x, y: pos.y, scale: 1.0, rotationRadians: 0, zIndex: z)
                state.imageURL = url
                session.broadcast(session.opAdd(sticker: state))
            }
        }
    }

    private func addStickerFromCapturedImage(_ image: UIImage) {
        let normalized = image.normalized()
        let stickerID = UUID()
        saveUndoState()
        topZ += 1
        let sticker = Sticker(
            id: stickerID,
            kind: .photo(normalized),
            position: visibleCenter(),
            scale: 1.0,
            rotation: .zero,
            zIndex: topZ
        )
        stickers.append(sticker)
        selectedStickerID = sticker.id

        if let session = collabSession {
            let pos = sticker.position; let z = sticker.zIndex; let img = normalized
            Task(priority: .utility) {
                guard let url = try? await StickerAssetUploader.uploadImage(img, stickerID: stickerID) else { return }
                await MainActor.run { uploadedURLs[stickerID] = url }
                var state = StickerState(id: stickerID, type: "photo",
                    x: pos.x, y: pos.y, scale: 1.0, rotationRadians: 0, zIndex: z)
                state.imageURL = url
                session.broadcast(session.opAdd(sticker: state))
            }
        }
    }

    private func addVideoSticker(result: VideoProcessor.Result) {
        saveUndoState()
        topZ += 1
        let sticker = Sticker(
            kind: .video(videoURL: result.outputURL, thumbnail: result.thumbnail, bgRemoved: result.bgRemoved),
            position: visibleCenter(),
            scale: 1.0,
            rotation: .zero,
            zIndex: topZ
        )
        stickers.append(sticker)
        selectedStickerID = sticker.id

        if let session = collabSession {
            let sid = sticker.id; let pos = sticker.position; let z = sticker.zIndex
            let srcURL = result.outputURL; let thumb = result.thumbnail; let bgRemoved = result.bgRemoved
            Task(priority: .utility) {
                guard let vURL = try? await StickerAssetUploader.uploadVideo(from: srcURL, stickerID: sid),
                      let tURL = try? await StickerAssetUploader.uploadVideoThumbnail(thumb, stickerID: sid) else { return }
                await MainActor.run { uploadedURLs[sid] = vURL; uploadedThumbnailURLs[sid] = tURL }
                var state = StickerState(id: sid, type: "video",
                    x: pos.x, y: pos.y, scale: 1.0, rotationRadians: 0, zIndex: z)
                state.videoURL = vURL; state.videoThumbnailURL = tURL; state.bgRemoved = bgRemoved
                session.broadcast(session.opAdd(sticker: state))
            }
        }
    }


    private func addMusicSticker(track: MusicTrack) {
        saveUndoState()
        topZ += 1
        let sticker = Sticker(
            kind: .music(track),
            position: visibleCenter(),
            scale: 1.0,
            rotation: .zero,
            zIndex: topZ
        )
        stickers.append(sticker)
        selectedStickerID = sticker.id

        if let session = collabSession {
            var state = StickerState(id: sticker.id, type: "music",
                x: sticker.position.x, y: sticker.position.y, scale: 1.0, rotationRadians: 0, zIndex: sticker.zIndex)
            state.musicID = track.id; state.musicTitle = track.title; state.musicArtist = track.artistName
            state.musicArtworkURLString = track.artworkURL?.absoluteString
            state.musicPreviewURLString = track.previewURL?.absoluteString
            session.broadcast(session.opAdd(sticker: state))
        }

        // Fetch artwork in background and update sticker
        Task {
            guard let artURL = track.artworkURL,
                  let (data, _) = try? await URLSession.shared.data(from: artURL),
                  let img = UIImage(data: data)
            else { return }
            if let idx = stickers.firstIndex(where: { $0.id == sticker.id }),
               case .music(var t) = stickers[idx].kind {
                t.artworkImage = img
                stickers[idx].kind = .music(t)
            }
        }
    }

    @MainActor
    private func loadBackgroundImage(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data)?.normalized()
        else { return }
        canvasBackground = .image(uiImage)
        bgPickerItem = nil
        showBackgroundSheet = false
        if let session = collabSession {
            let img = uiImage
            Task(priority: .utility) {
                let bgID = UUID()
                guard let url = try? await StickerAssetUploader.uploadImage(img, stickerID: bgID) else { return }
                session.broadcast(session.opUpdateBackground(imageURL: url))
            }
        }
    }

    private func saveUndoState() {
        undoStack.append(CanvasSnapshot(stickers: stickers, topZ: topZ))
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    private func undo() {
        guard let snapshot = undoStack.popLast() else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let before = stickers
        withAnimation(.spring(duration: 0.25)) {
            stickers = snapshot.stickers
            topZ = snapshot.topZ
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        broadcastUndoDiff(before: before, after: snapshot.stickers)
    }

    /// Diffs two canvas states and broadcasts the minimum set of ops to bring
    /// remote collaborators to the post-undo state. Uses existing op types so
    /// no protocol changes are needed.
    private func broadcastUndoDiff(before: [Sticker], after: [Sticker]) {
        guard let session = collabSession else { return }

        let beforeIDs = Set(before.map { $0.id })
        let afterIDs  = Set(after.map  { $0.id })

        // Stickers removed by undo (were added before undo) → delete on remote
        for s in before where !afterIDs.contains(s.id) {
            session.broadcast(session.opDelete(stickerID: s.id))
        }

        // Stickers restored by undo (were deleted before undo) → re-add on remote
        for s in after where !beforeIDs.contains(s.id) {
            var state = StickerState(id: s.id, type: "", x: s.position.x, y: s.position.y,
                                     scale: s.scale, rotationRadians: s.rotation.radians, zIndex: s.zIndex)
            switch s.kind {
            case .photo:
                state.type = "photo"
                state.imageURL      = uploadedURLs[s.id]
                state.imageFilename = "\(s.id.uuidString).png"
                guard state.imageURL != nil else { continue } // upload still in progress — skip
            case .text(let c):
                state.type = "text"; state.textString = c.text; state.fontIndex = c.fontIndex
                state.colorIndex = c.colorIndex; state.textWrapWidth = Double(c.wrapWidth)
                state.textAlignment = c.alignment; state.textBGStyle = c.bgStyle
            case .music(let t):
                state.type = "music"; state.musicID = t.id; state.musicTitle = t.title
                state.musicArtist = t.artistName
                state.musicArtworkURLString = t.artworkURL?.absoluteString
                state.musicPreviewURLString = t.previewURL?.absoluteString
            case .video:
                state.type = "video"
                state.videoURL = uploadedURLs[s.id]
                guard state.videoURL != nil else { continue }
            }
            session.broadcast(session.opAdd(sticker: state))
        }

        // Stickers that changed position/scale/rotation/zIndex
        for s in after where beforeIDs.contains(s.id) {
            guard let old = before.first(where: { $0.id == s.id }) else { continue }
            if s.position != old.position {
                session.broadcast(session.opMove(stickerID: s.id, x: s.position.x, y: s.position.y))
            }
            if s.scale != old.scale {
                session.broadcast(session.opScale(stickerID: s.id, scale: s.scale))
            }
            if s.rotation.radians != old.rotation.radians {
                session.broadcast(session.opRotate(stickerID: s.id, radians: s.rotation.radians))
            }
            if s.zIndex != old.zIndex {
                session.broadcast(session.opReorder(stickerID: s.id, zIndex: s.zIndex))
            }
        }
    }

    private func bringToFront(stickerID: UUID) {
        guard let idx = stickers.firstIndex(where: { $0.id == stickerID }) else { return }
        topZ += 1
        stickers[idx].zIndex = topZ
        collabSession?.broadcast(collabSession!.opReorder(stickerID: stickerID, zIndex: topZ))
    }

    private func visibleCenter() -> CGPoint {
        if canvasMode == .vertical, let view = canvasUIView {
            return view.verticalVisibleCenter()
        }
        let safeScale = max(canvasScale, 0.0001)
        return CGPoint(
            x: canvasSize / 2 - canvasOffset.width  / safeScale,
            y: canvasSize / 2 - canvasOffset.height / safeScale
        )
    }
}

// MARK: - Undo Model

private struct CanvasSnapshot {
    let stickers: [Sticker]
    let topZ: Double
}

// MARK: - Sticker Model

enum StickerKind {
    case photo(UIImage)
    case text(TextStickerContent)
    case music(MusicTrack)
    case video(videoURL: URL, thumbnail: UIImage, bgRemoved: Bool = false)
}

struct Sticker: Identifiable, Equatable {
    let id: UUID
    var kind: StickerKind
    var position: CGPoint
    var scale: CGFloat
    var rotation: Angle
    var zIndex: Double

    init(id: UUID = UUID(), kind: StickerKind, position: CGPoint,
         scale: CGFloat = 1.0, rotation: Angle = .zero, zIndex: Double = 0) {
        self.id       = id
        self.kind     = kind
        self.position = position
        self.scale    = scale
        self.rotation = rotation
        self.zIndex   = zIndex
    }

    // Convenience accessors
    var image: UIImage? {
        switch kind {
        case .photo(let img): return img
        case .text(let c):    return c.image
        default:              return nil
        }
    }
    var musicTrack: MusicTrack? {
        if case .music(let t) = kind { return t }
        return nil
    }

    static func == (lhs: Sticker, rhs: Sticker) -> Bool {
        guard lhs.id == rhs.id, lhs.position == rhs.position,
              lhs.scale == rhs.scale, lhs.rotation == rhs.rotation,
              lhs.zIndex == rhs.zIndex else { return false }
        switch (lhs.kind, rhs.kind) {
        case (.photo(let a), .photo(let b)):
            return a === b   // UIImage is a class; pointer equality detects background removal
        case (.video(let ua, let ta, let ba), .video(let ub, let tb, let bb)):
            return ua == ub && ta === tb && ba == bb
        case (.text(let a), .text(let b)):
            return a.text == b.text && a.fontIndex == b.fontIndex &&
                   a.colorIndex == b.colorIndex && a.wrapWidth == b.wrapWidth &&
                   a.alignment == b.alignment && a.bgStyle == b.bgStyle
        case (.music(let a), .music(let b)):
            return a.id == b.id
        default: return false
        }
    }
}

// MARK: - CanvasHostView

struct CanvasHostView: UIViewRepresentable {
    @Binding var stickers: [Sticker]
    @Binding var selectedStickerID: UUID?
    @Binding var canvasScale: CGFloat
    @Binding var canvasOffset: CGSize
    let canvasBackground: CanvasBackground
    let canvasMode: CanvasMode
    let onTapEmpty: () -> Void
    let onTapSticker: (UUID) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint, UUID) -> Void
    let onStickerGestureStart: () -> Void
    var onStickerGestureEnded: ((UUID) -> Void)? = nil
    let onTextEdit: (UUID) -> Void
    var onPhotoReplaced: ((UUID, UIImage) -> Void)? = nil
    var onViewReady: ((CanvasUIView) -> Void)? = nil

    func makeCoordinator() -> CanvasCoordinator {
        CanvasCoordinator(
            stickers: $stickers,
            selectedStickerID: $selectedStickerID,
            canvasScale: $canvasScale,
            canvasOffset: $canvasOffset,
            onTapEmpty: onTapEmpty,
            onTapSticker: onTapSticker
        )
    }

    func makeUIView(context: Context) -> CanvasUIView {
        let view = CanvasUIView(coordinator: context.coordinator, mode: canvasMode)
        context.coordinator.onDoubleTap = { [weak view] stickerID in
            view?.enterLassoMode(stickerID: stickerID)
        }
        onViewReady?(view)
        return view
    }

    func updateUIView(_ view: CanvasUIView, context: Context) {
        context.coordinator.stickers = $stickers
        context.coordinator.selectedStickerID = $selectedStickerID
        context.coordinator.onTapEmpty = onTapEmpty
        context.coordinator.onTapSticker = onTapSticker
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onStickerGestureStart = onStickerGestureStart
        context.coordinator.onStickerGestureEnded = onStickerGestureEnded
        context.coordinator.onTextEdit = onTextEdit
        context.coordinator.onPhotoReplaced = onPhotoReplaced

        view.syncBackground(canvasBackground)

        // Always apply the canvas pan/zoom transform — this is cheap
        view.applyCanvasTransform(scale: canvasScale, offset: canvasOffset)

        // Only run the expensive sticker sync when content actually changed
        view.syncStickersIfNeeded(
            stickers: stickers,
            selectedID: selectedStickerID
        )
    }
}

// MARK: - CanvasUIView

final class CanvasUIView: UIView {

    /// Renders an explicit screen-coordinate rect of the canvas layer to a UIImage.
    /// The captureRect should be in the same coordinate space as the UIView (screen coordinates
    /// starting at 0,0 at the top of the screen). Used by the cover picker overlay.
    func renderViewportThumbnail(in captureRect: CGRect) -> UIImage? {
        let gridWasHidden = gridLayer.isHidden
        gridLayer.isHidden = true
        defer { gridLayer.isHidden = gridWasHidden }

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)

        // AVPlayerLayer is GPU-rendered and invisible to layer.render(in:).
        // Snapshot each video sticker's current frame on the main thread now,
        // along with its position/transform, so we can composite them manually.
        struct VideoRenderInfo {
            let centerInCanvas: CGPoint   // center in canvasView space
            let centerInSelf: CGPoint     // center in CanvasUIView space (infinite canvas)
            let transform: CGAffineTransform
            let image: UIImage
        }
        let videoInfos: [VideoRenderInfo] = videoViews.compactMap { (_, vv) in
            guard let image = vv.currentFrameImage() else { return nil }
            return VideoRenderInfo(
                centerInCanvas: vv.center,
                centerInSelf: canvasView.convert(vv.center, to: self),
                transform: vv.transform,
                image: image
            )
        }

        let stickerSize = VideoStickerUIView.size

        if isVertical {
            let rectInCanvas = convert(captureRect, to: canvasView)
            let scale = captureRect.width / rectInCanvas.width
            return renderer.image { ctx in
                ctx.cgContext.scaleBy(x: scale, y: scale)
                ctx.cgContext.translateBy(x: -rectInCanvas.origin.x, y: -rectInCanvas.origin.y)
                canvasView.layer.render(in: ctx.cgContext)
                // Composite video frames — drawn in canvasView coordinate space
                for info in videoInfos {
                    ctx.cgContext.saveGState()
                    ctx.cgContext.translateBy(x: info.centerInCanvas.x, y: info.centerInCanvas.y)
                    ctx.cgContext.concatenate(info.transform)
                    info.image.draw(in: CGRect(x: -stickerSize / 2, y: -stickerSize / 2,
                                               width: stickerSize, height: stickerSize))
                    ctx.cgContext.restoreGState()
                }
            }
        }

        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: -captureRect.origin.x, y: -captureRect.origin.y)
            layer.render(in: ctx.cgContext)
            // Composite video frames — drawn in CanvasUIView coordinate space
            for info in videoInfos {
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: info.centerInSelf.x, y: info.centerInSelf.y)
                ctx.cgContext.concatenate(info.transform)
                info.image.draw(in: CGRect(x: -stickerSize / 2, y: -stickerSize / 2,
                                           width: stickerSize, height: stickerSize))
                ctx.cgContext.restoreGState()
            }
        }
    }

    /// Renders the currently visible viewport to a UIImage at the given aspect ratio (width/height).
    /// Used for the "Edit Cover" screenshot capture.
    func renderViewportThumbnail(aspectRatio: CGFloat = 1.0) -> UIImage? {
        let gridWasHidden = gridLayer.isHidden
        gridLayer.isHidden = true

        let captureW = min(bounds.width, bounds.height * aspectRatio)
        let captureH = captureW / aspectRatio
        let captureRect = CGRect(
            x: (bounds.width  - captureW) / 2,
            y: (bounds.height - captureH) / 2,
            width: captureW, height: captureH
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: captureRect, format: format)
        let image = renderer.image { ctx in
            ctx.cgContext.translateBy(x: -captureRect.origin.x, y: -captureRect.origin.y)
            layer.render(in: ctx.cgContext)
        }

        gridLayer.isHidden = gridWasHidden
        return image
    }

    private weak var coordinator: CanvasCoordinator?

    let canvasView = UIView()
    private let backgroundColorView = UIView()
    private let backgroundImageView = UIImageView()
    let gridLayer = CanvasGridView()

    private var stickerViews: [UUID: StickerUIView] = [:]
    private var stickerCoordinators: [UUID: StickerCoordinator] = [:]
    private var musicViews: [UUID: MusicStickerUIView] = [:]
    private var musicCoordinators: [UUID: MusicStickerCoordinator] = [:]
    private var videoViews: [UUID: VideoStickerUIView] = [:]
    private var videoCoordinators: [UUID: VideoStickerCoordinator] = [:]

    private(set) var scrollView: UIScrollView?
    let isVertical: Bool

    // Height of the vertical feed canvas in points
    private static let verticalCanvasHeight: CGFloat = 3000

    init(coordinator: CanvasCoordinator, mode: CanvasMode = .infinite) {
        self.coordinator = coordinator
        self.isVertical  = mode == .vertical
        super.init(frame: .zero)
        backgroundColor = UIColor.systemBackground

        if isVertical {
            // Vertical feed: scrollable canvas with fixed width, tall height
            let w = UIScreen.main.bounds.width
            let h = CanvasUIView.verticalCanvasHeight
            canvasView.frame = CGRect(x: 0, y: 0, width: w, height: h)
            canvasView.backgroundColor = .clear

            let sv = UIScrollView()
            sv.showsHorizontalScrollIndicator = false
            sv.alwaysBounceVertical = true
            sv.contentSize = CGSize(width: w, height: h)
            // Pinch-to-zoom: allow zooming in freely, slight zoom-out to get context
            sv.minimumZoomScale = 0.6
            sv.maximumZoomScale = 4.0
            sv.delegate = self
            addSubview(sv)
            sv.addSubview(canvasView)
            scrollView = sv
        } else {
            // Infinite canvas: 2000×2000 free-roam canvas
            canvasView.frame = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
            canvasView.backgroundColor = .clear
            addSubview(canvasView)
        }

        // Background color fill
        backgroundColorView.frame = canvasView.bounds
        backgroundColorView.backgroundColor = .white
        backgroundColorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.addSubview(backgroundColorView)

        // Background image (hidden until set)
        backgroundImageView.frame = canvasView.bounds
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.isHidden = true
        backgroundImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.addSubview(backgroundImageView)

        gridLayer.frame = canvasView.bounds
        gridLayer.backgroundColor = .clear
        gridLayer.isHidden = isVertical   // no grid on vertical canvas
        canvasView.addSubview(gridLayer)

        if !isVertical {
            let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleCanvasPan))
            pan.delegate = coordinator
            coordinator.canvasPan = pan
            addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleCanvasPinch))
            pinch.delegate = coordinator
            coordinator.canvasPinch = pinch
            addGestureRecognizer(pinch)
        }

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleCanvasTap))
        tap.delegate = coordinator
        // In vertical mode attach tap to the scrollView so it works while scrolling
        (scrollView ?? self).addGestureRecognizer(tap)

        coordinator.canvasView = canvasView
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Returns the canvas-space point currently visible in the center of the scrollable vertical canvas
    func verticalVisibleCenter() -> CGPoint {
        let offsetY = scrollView?.contentOffset.y ?? 0
        return CGPoint(x: canvasView.bounds.width / 2, y: offsetY + bounds.height / 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isVertical {
            scrollView?.frame = bounds
        } else {
            coordinator?.centerCanvasIfNeeded(in: bounds)
        }
    }


    func syncBackground(_ background: CanvasBackground) {
        switch background {
        case .color(let color):
            backgroundColorView.backgroundColor = color
            backgroundColorView.isHidden = false
            backgroundImageView.isHidden = true
            gridLayer.isHidden = isVertical   // always hide grid on vertical canvas
        case .image(let image):
            backgroundImageView.image = image
            backgroundImageView.isHidden = false
            backgroundColorView.isHidden = true
            gridLayer.isHidden = true   // hide grid over photo backgrounds
        }
    }

    // Lightweight transform-only update — called every frame during pan/pinch (no-op in vertical mode)
    func applyCanvasTransform(scale: CGFloat, offset: CGSize) {
        guard !isVertical else { return }
        canvasView.transform = CGAffineTransform(scaleX: scale, y: scale)
        canvasView.center = CGPoint(
            x: bounds.midX + offset.width,
            y: bounds.midY + offset.height
        )
    }

    // MARK: - Lasso tool

    private var lassoOverlay: LassoOverlayView?

    func enterLassoMode(stickerID: UUID) {
        guard lassoOverlay == nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Set the flag FIRST — sticker gesture cancellations triggered by the double-tap
        // recognizer will call gestureEnd, which re-enables canvasPan/canvasPinch unless
        // this flag is already set.
        coordinator?.isLassoActive = true

        // Freeze canvas gestures while lasso is active
        coordinator?.canvasPan?.isEnabled   = false
        coordinator?.canvasPinch?.isEnabled = false

        let overlay = LassoOverlayView(frame: bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.alpha = 0
        addSubview(overlay)
        lassoOverlay = overlay

        UIView.animate(withDuration: 0.2) { overlay.alpha = 1 }

        overlay.onComplete = { [weak self] points in
            guard let self else { return }
            UIView.animate(withDuration: 0.15) { overlay.alpha = 0 } completion: { _ in
                overlay.removeFromSuperview()
            }
            self.lassoOverlay = nil
            self.coordinator?.isLassoActive     = false
            self.coordinator?.canvasPan?.isEnabled   = true
            self.coordinator?.canvasPinch?.isEnabled = true
            self.applyLasso(points: points, stickerID: stickerID)
        }
        overlay.onCancel = { [weak self] in
            UIView.animate(withDuration: 0.2) { overlay.alpha = 0 } completion: { _ in
                overlay.removeFromSuperview()
            }
            self?.lassoOverlay = nil
            self?.coordinator?.isLassoActive     = false
            self?.coordinator?.canvasPan?.isEnabled   = true
            self?.coordinator?.canvasPinch?.isEnabled = true
        }
    }

    private func applyLasso(points: [CGPoint], stickerID: UUID) {
        if let sv = stickerViews[stickerID], let sc = stickerCoordinators[stickerID] {
            guard case .photo(let image) = sc.sticker.wrappedValue.kind else { return }
            let localPoints = points.map { sv.convert($0, from: self) }
            guard localPoints.count >= 3,
                  let masked = buildLassoMaskedImage(image: image, localPoints: localPoints),
                  let idx = coordinator?.stickers.wrappedValue.firstIndex(where: { $0.id == stickerID })
            else { return }
            // Clear sync cache so the image change is picked up by the next syncStickersIfNeeded call
            lastSyncedStickers = nil
            coordinator?.stickers.wrappedValue[idx].kind = .photo(masked)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Save masked image to disk immediately so it survives app restarts,
            // and notify the canvas (broadcasts to collab peers + updates uploadedURLs).
            let fn = "\(stickerID.uuidString).png"
            Task.detached(priority: .utility) { StickerStorage.saveImage(masked, filename: fn) }
            coordinator?.onPhotoReplaced?(stickerID, masked)

        } else if let vv = videoViews[stickerID] {
            let localPoints = points.map { vv.convert($0, from: self) }
            guard localPoints.count >= 3 else { return }
            let path = UIBezierPath()
            path.move(to: localPoints[0])
            for p in localPoints.dropFirst() { path.addLine(to: p) }
            path.close()
            let maskLayer = CAShapeLayer()
            maskLayer.path = path.cgPath
            vv.layer.mask = maskLayer
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// Mask a UIImage using a lasso path expressed in StickerUIView bounds space (−110…110).
    private func buildLassoMaskedImage(image: UIImage, localPoints: [CGPoint]) -> UIImage? {
        let viewSize: CGFloat = 220
        let W = image.size.width
        let H = image.size.height
        guard W > 0, H > 0 else { return nil }

        // The image is scaleAspectFit inside a 220×220 region centered at (0,0) in bounds space
        let scale  = min(viewSize / W, viewSize / H)
        let drawnW = W * scale
        let drawnH = H * scale
        let drawRect = CGRect(x: -drawnW / 2, y: -drawnH / 2, width: drawnW, height: drawnH)

        // Convert path from sticker-bounds space → image pixel space
        let imagePoints = localPoints.map { p in
            CGPoint(
                x: (p.x - drawRect.minX) / scale,
                y: (p.y - drawRect.minY) / scale
            )
        }
        let maskPath = UIBezierPath()
        maskPath.move(to: imagePoints[0])
        for p in imagePoints.dropFirst() { maskPath.addLine(to: p) }
        maskPath.close()

        let format = UIGraphicsImageRendererFormat()
        format.scale  = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            maskPath.addClip()
            image.draw(at: .zero)
        }
    }

    // Tracks previous values to skip redundant sticker syncs
    private var lastSyncedStickers:  [Sticker]? = nil
    private var lastSyncedSelection: UUID?       = nil

    func invalidateStickerCache() {
        lastSyncedStickers = nil
    }

    func syncStickersIfNeeded(stickers: [Sticker], selectedID: UUID?) {
        // Skip if nothing changed — e.g. pure pan/pinch updates
        let stickersSame  = lastSyncedStickers.map { $0.elementsEqual(stickers, by: { a, b in
            guard a.id == b.id && a.position == b.position &&
                  a.scale == b.scale && a.rotation == b.rotation && a.zIndex == b.zIndex
            else { return false }
            switch (a.kind, b.kind) {
            case (.photo(let ia), .photo(let ib)):
                return ia === ib   // pointer equality detects background removal
            case (.text(let ta), .text(let tb)):
                return ta.text == tb.text && ta.fontIndex == tb.fontIndex &&
                       ta.colorIndex == tb.colorIndex && ta.wrapWidth == tb.wrapWidth &&
                       ta.alignment == tb.alignment && ta.bgStyle == tb.bgStyle
            case (.music(let ma), .music(let mb)):
                return ma.artworkImage === mb.artworkImage
            default:
                return true
            }
        }) } ?? false
        let selectionSame = lastSyncedSelection == selectedID
        guard !stickersSame || !selectionSame else { return }
        lastSyncedStickers  = stickers
        lastSyncedSelection = selectedID
        syncStickers(stickers: stickers, selectedID: selectedID)
    }

    func syncStickers(stickers: [Sticker], selectedID: UUID?) {
        guard let coordinator else { return }

        let newIDs = Set(stickers.map(\.id))

        // Remove deleted photo stickers
        for id in Set(stickerViews.keys).subtracting(newIDs) {
            stickerViews[id]?.removeFromSuperview()
            stickerViews[id] = nil; stickerCoordinators[id] = nil
        }
        // Remove deleted music stickers
        for id in Set(musicViews.keys).subtracting(newIDs) {
            musicViews[id]?.removeFromSuperview()
            musicViews[id] = nil; musicCoordinators[id] = nil
        }
        // Remove deleted video stickers
        for id in Set(videoViews.keys).subtracting(newIDs) {
            videoViews[id]?.removeFromSuperview()
            videoViews[id] = nil; videoCoordinators[id] = nil
        }

        let sorted = stickers.sorted { $0.zIndex < $1.zIndex }

        let gestureStart: () -> Void = { [weak coordinator] in
            coordinator?.onStickerGestureStart?()
            coordinator?.canvasPan?.isEnabled = false
            coordinator?.canvasPinch?.isEnabled = false
        }
        let gestureEnd: () -> Void = { [weak coordinator] in
            guard coordinator?.isLassoActive != true else { return }
            coordinator?.canvasPan?.isEnabled = true
            coordinator?.canvasPinch?.isEnabled = true
        }

        for sticker in sorted {
            switch sticker.kind {
            case .photo(let img):
                if stickerViews[sticker.id] == nil {
                    let binding = coordinator.bindingForSticker(id: sticker.id)
                    let sc = StickerCoordinator(
                        sticker: binding,
                        onTapSelect: { [weak self] in
                            self?.coordinator?.onTapSticker(sticker.id)
                        }
                    )
                    let sid = sticker.id
                    sc.onGestureStart = gestureStart
                    sc.onGestureEnd = { [weak coordinator, sid] in
                        guard coordinator?.isLassoActive != true else { return }
                        coordinator?.canvasPan?.isEnabled = true
                        coordinator?.canvasPinch?.isEnabled = true
                        coordinator?.onStickerGestureEnded?(sid)
                    }
                    sc.onDragChanged = { [weak coordinator] p in coordinator?.onDragChanged?(p) }
                    sc.onDragEnded   = { [weak coordinator] p in coordinator?.onDragEnded?(p, sid) }
                    sc.onDoubleTap   = { [weak coordinator] in coordinator?.onDoubleTap?(sid) }
                    sc.onPhotoReplaced = { [weak coordinator, sid] img in coordinator?.onPhotoReplaced?(sid, img) }
                    let sv = StickerUIView(coordinator: sc)
                    stickerCoordinators[sticker.id] = sc
                    stickerViews[sticker.id] = sv
                    canvasView.addSubview(sv)
                }
                let sv = stickerViews[sticker.id]!
                let sc = stickerCoordinators[sticker.id]!
                sc.sticker = coordinator.bindingForSticker(id: sticker.id)
                let photoID = sticker.id
                sc.onPhotoReplaced = { [weak coordinator, photoID] img in coordinator?.onPhotoReplaced?(photoID, img) }
                sv.center = sticker.position
                if !sc.isGesturing {
                    sv.transform = CGAffineTransform(rotationAngle: sticker.rotation.radians)
                        .scaledBy(x: sticker.scale, y: sticker.scale)
                }
                sv.configure(image: img, isSelected: selectedID == sticker.id)
                canvasView.bringSubviewToFront(sv)

            case .text(let content):
                if stickerViews[sticker.id] == nil {
                    let binding = coordinator.bindingForSticker(id: sticker.id)
                    let sc = StickerCoordinator(
                        sticker: binding,
                        onTapSelect: { [weak self] in
                            self?.coordinator?.onTapSticker(sticker.id)
                        }
                    )
                    let sid = sticker.id
                    sc.onGestureStart = gestureStart
                    sc.onGestureEnd = { [weak coordinator, sid] in
                        guard coordinator?.isLassoActive != true else { return }
                        coordinator?.canvasPan?.isEnabled = true
                        coordinator?.canvasPinch?.isEnabled = true
                        coordinator?.onStickerGestureEnded?(sid)
                    }
                    sc.onDragChanged = { [weak coordinator] p in coordinator?.onDragChanged?(p) }
                    sc.onDragEnded   = { [weak coordinator] p in coordinator?.onDragEnded?(p, sid) }
                    // Double-tap opens the text editor; long press is left free so dragging isn't blocked
                    sc.onDoubleTap   = { [weak coordinator] in
                        DispatchQueue.main.async { coordinator?.onTextEdit?(sid) }
                    }
                    let sv = StickerUIView(coordinator: sc)
                    sv.usesBoundingBoxHitTest = true
                    stickerCoordinators[sticker.id] = sc
                    stickerViews[sticker.id] = sv
                    canvasView.addSubview(sv)
                }
                let sv = stickerViews[sticker.id]!
                let sc = stickerCoordinators[sticker.id]!
                sc.sticker = coordinator.bindingForSticker(id: sticker.id)
                sv.center = sticker.position
                if !sc.isGesturing {
                    sv.transform = CGAffineTransform(rotationAngle: sticker.rotation.radians)
                        .scaledBy(x: sticker.scale, y: sticker.scale)
                }
                sv.configure(image: content.image, isSelected: selectedID == sticker.id)
                canvasView.bringSubviewToFront(sv)

            case .music(let track):
                if musicViews[sticker.id] == nil {
                    let sid = sticker.id
                    let mc = MusicStickerCoordinator(
                        stickerID: sid,
                        previewURL: track.previewURL
                    )
                    mc.onTapSelect = { [weak self] in
                        self?.coordinator?.onTapSticker(sid)
                    }
                    mc.onGestureStart = gestureStart
                    mc.onGestureEnd = { [weak coordinator, sid] in
                        guard coordinator?.isLassoActive != true else { return }
                        coordinator?.canvasPan?.isEnabled = true
                        coordinator?.canvasPinch?.isEnabled = true
                        coordinator?.onStickerGestureEnded?(sid)
                    }
                    mc.onPositionChanged = { [weak self] newPos in
                        guard let self,
                              let idx = self.coordinator?.stickers.wrappedValue.firstIndex(where: { $0.id == sid })
                        else { return }
                        self.coordinator?.stickers.wrappedValue[idx].position = newPos
                    }
                    mc.onDragChanged = { [weak coordinator] p in coordinator?.onDragChanged?(p) }
                    mc.onDragEnded   = { [weak coordinator] p in coordinator?.onDragEnded?(p, sid) }
                    mc.currentScale = { [weak self] in
                        self?.coordinator?.stickers.wrappedValue.first(where: { $0.id == sid })?.scale ?? 1.0
                    }
                    mc.currentRotation = { [weak self] in
                        self?.coordinator?.stickers.wrappedValue.first(where: { $0.id == sid })?.rotation.radians ?? 0.0
                    }
                    mc.onScaleChanged = { [weak self] newScale in
                        guard let self,
                              let idx = self.coordinator?.stickers.wrappedValue.firstIndex(where: { $0.id == sid })
                        else { return }
                        self.coordinator?.stickers.wrappedValue[idx].scale = newScale
                        if let mv = self.musicViews[sid],
                           let rot = self.coordinator?.stickers.wrappedValue[idx].rotation.radians {
                            mv.transform = CGAffineTransform(rotationAngle: rot).scaledBy(x: newScale, y: newScale)
                        }
                    }
                    mc.onRotationChanged = { [weak self] newAngle in
                        guard let self,
                              let idx = self.coordinator?.stickers.wrappedValue.firstIndex(where: { $0.id == sid })
                        else { return }
                        self.coordinator?.stickers.wrappedValue[idx].rotation = .init(radians: newAngle)
                        if let mv = self.musicViews[sid],
                           let sc = self.coordinator?.stickers.wrappedValue[idx].scale {
                            mv.transform = CGAffineTransform(rotationAngle: newAngle).scaledBy(x: sc, y: sc)
                        }
                    }
                    let mv = MusicStickerUIView(coordinator: mc)
                    musicCoordinators[sticker.id] = mc
                    musicViews[sticker.id] = mv
                    canvasView.addSubview(mv)
                }
                let mv = musicViews[sticker.id]!
                mv.center = sticker.position
                mv.transform = CGAffineTransform(rotationAngle: sticker.rotation.radians)
                    .scaledBy(x: sticker.scale, y: sticker.scale)
                mv.configure(track: track, isSelected: selectedID == sticker.id)
                canvasView.bringSubviewToFront(mv)

            case .video(let videoURL, let thumbnail, let bgRemoved):
                if videoViews[sticker.id] == nil {
                    let sid = sticker.id
                    let vc = VideoStickerCoordinator(stickerID: sid)
                    vc.onTapSelect = { [weak self] in
                        self?.coordinator?.onTapSticker(sid)
                    }
                    vc.onDoubleTap   = { [weak coordinator] in coordinator?.onDoubleTap?(sid) }
                    vc.onGestureStart = gestureStart
                    vc.onGestureEnd = { [weak coordinator, sid] in
                        guard coordinator?.isLassoActive != true else { return }
                        coordinator?.canvasPan?.isEnabled = true
                        coordinator?.canvasPinch?.isEnabled = true
                        coordinator?.onStickerGestureEnded?(sid)
                    }
                    vc.onPositionChanged = { [weak self] newPos in
                        guard let self,
                              let idx = self.coordinator?.stickers.wrappedValue.firstIndex(where: { $0.id == sid })
                        else { return }
                        self.coordinator?.stickers.wrappedValue[idx].position = newPos
                    }
                    vc.onDragChanged = { [weak coordinator] p in coordinator?.onDragChanged?(p) }
                    vc.onDragEnded   = { [weak coordinator] p in coordinator?.onDragEnded?(p, sid) }
                    vc.currentScale = { [weak self] in
                        self?.coordinator?.stickers.wrappedValue
                            .first(where: { $0.id == sid })?.scale ?? 1.0
                    }
                    vc.currentRotation = { [weak self] in
                        self?.coordinator?.stickers.wrappedValue
                            .first(where: { $0.id == sid })?.rotation.radians ?? 0.0
                    }
                    vc.onScaleChanged = { [weak self] newScale in
                        guard let self,
                              let idx = self.coordinator?.stickers.wrappedValue.firstIndex(where: { $0.id == sid })
                        else { return }
                        self.coordinator?.stickers.wrappedValue[idx].scale = newScale
                        if let vv = self.videoViews[sid],
                           let rot = self.coordinator?.stickers.wrappedValue[idx].rotation.radians {
                            vv.transform = CGAffineTransform(rotationAngle: rot).scaledBy(x: newScale, y: newScale)
                        }
                    }
                    vc.onRotationChanged = { [weak self] newAngle in
                        guard let self,
                              let idx = self.coordinator?.stickers.wrappedValue.firstIndex(where: { $0.id == sid })
                        else { return }
                        self.coordinator?.stickers.wrappedValue[idx].rotation = .init(radians: newAngle)
                        if let vv = self.videoViews[sid],
                           let sc = self.coordinator?.stickers.wrappedValue[idx].scale {
                            vv.transform = CGAffineTransform(rotationAngle: newAngle).scaledBy(x: sc, y: sc)
                        }
                    }
                    let vv = VideoStickerUIView(coordinator: vc)
                    videoCoordinators[sticker.id] = vc
                    videoViews[sticker.id] = vv
                    canvasView.addSubview(vv)
                }
                let vv = videoViews[sticker.id]!
                let vc = videoCoordinators[sticker.id]!
                vv.center = sticker.position
                vv.transform = CGAffineTransform(rotationAngle: sticker.rotation.radians)
                    .scaledBy(x: sticker.scale, y: sticker.scale)
                vv.configure(videoURL: videoURL, thumbnail: thumbnail,
                             isSelected: selectedID == sticker.id, bgRemoved: bgRemoved)
                canvasView.bringSubviewToFront(vv)
            }
        }
    }
}

// MARK: - CanvasUIView + UIScrollViewDelegate (vertical zoom)

extension CanvasUIView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        // Zoom the entire canvas (stickers + background) as one unit
        canvasView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keep the canvas centred when zoomed out below the viewport size.
        // Without this it snaps to the top-left corner on zoom-out.
        let horizontalInset = max((scrollView.bounds.width  - scrollView.contentSize.width)  / 2, 0)
        let verticalInset   = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset, left: horizontalInset,
            bottom: verticalInset, right: horizontalInset
        )
    }
}

// MARK: - CanvasGridView

final class CanvasGridView: UIView {
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.2).cgColor)
        ctx.setLineWidth(1)
        let step: CGFloat = 120
        var x: CGFloat = 0
        while x <= rect.width  { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: rect.height)); x += step }
        var y: CGFloat = 0
        while y <= rect.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: rect.width, y: y)); y += step }
        ctx.strokePath()
    }
}

// MARK: - Shake Detection

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

private final class ShakeViewController: UIViewController {
    override var canBecomeFirstResponder: Bool { true }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
    }
}

private struct ShakeDetector: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ShakeViewController {
        let vc = ShakeViewController()
        vc.becomeFirstResponder()
        return vc
    }
    func updateUIViewController(_ vc: ShakeViewController, context: Context) {}
}

// MARK: - CanvasCoordinator

final class CanvasCoordinator: NSObject, UIGestureRecognizerDelegate {
    var stickers: Binding<[Sticker]>
    var selectedStickerID: Binding<UUID?>
    var canvasScale: Binding<CGFloat>
    var canvasOffset: Binding<CGSize>
    var onTapEmpty: () -> Void
    var onTapSticker: (UUID) -> Void
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint, UUID) -> Void)?
    var onStickerGestureStart: (() -> Void)?
    var onStickerGestureEnded: ((UUID) -> Void)?
    var onTextEdit: ((UUID) -> Void)?
    var onDoubleTap: ((UUID) -> Void)?
    var onPhotoReplaced: ((UUID, UIImage) -> Void)?
    weak var canvasView: UIView?
    weak var canvasPan: UIPanGestureRecognizer?
    weak var canvasPinch: UIPinchGestureRecognizer?
    var isLassoActive: Bool = false

    private var panStartOffset: CGSize = .zero
    private var pinchStartScale: CGFloat = 1.0

    init(stickers: Binding<[Sticker]>, selectedStickerID: Binding<UUID?>,
         canvasScale: Binding<CGFloat>, canvasOffset: Binding<CGSize>,
         onTapEmpty: @escaping () -> Void, onTapSticker: @escaping (UUID) -> Void) {
        self.stickers = stickers
        self.selectedStickerID = selectedStickerID
        self.canvasScale = canvasScale
        self.canvasOffset = canvasOffset
        self.onTapEmpty = onTapEmpty
        self.onTapSticker = onTapSticker
    }

    func centerCanvasIfNeeded(in bounds: CGRect) {
        guard canvasOffset.wrappedValue == .zero, let cv = canvasView else { return }
        cv.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func bindingForSticker(id: UUID) -> Binding<Sticker> {
        Binding(
            get: {
                if let found = self.stickers.wrappedValue.first(where: { $0.id == id }) {
                    return found
                }
                // Fallback should never be hit; return a stable placeholder instead of crashing.
                return Sticker(kind: .photo(UIImage()), position: .zero, scale: 1, rotation: .zero, zIndex: 0)
            },
            set: { newValue in
                guard let idx = self.stickers.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
                self.stickers.wrappedValue[idx] = newValue
            }
        )
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc func handleCanvasTap(_ gr: UITapGestureRecognizer) { onTapEmpty() }

    @objc func handleCanvasPan(_ gr: UIPanGestureRecognizer) {
        guard let view = gr.view else { return }
        switch gr.state {
        case .began:
            panStartOffset = canvasOffset.wrappedValue
        case .changed:
            let t = gr.translation(in: view)
            canvasOffset.wrappedValue = CGSize(width: panStartOffset.width + t.x,
                                               height: panStartOffset.height + t.y)
        default: break
        }
    }

    @objc func handleCanvasPinch(_ gr: UIPinchGestureRecognizer) {
        switch gr.state {
        case .began:
            pinchStartScale = canvasScale.wrappedValue
        case .changed:
            canvasScale.wrappedValue = min(max(pinchStartScale * gr.scale, 0.25), 4.0)
        default: break
        }
    }
}


