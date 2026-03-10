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
    var onCoverPicked: ((UIImage) -> Void)? = nil
    var onCoverCancelled: (() -> Void)? = nil

    @Environment(TapestryStore.self) private var store

    @State private var stickers: [Sticker] = []
    @State private var selectedStickerID: UUID?
    @State private var topZ: Double = 0
    @State private var canvasScale: CGFloat = 1.0
    @State private var canvasOffset: CGSize = .zero

    // Background
    @State private var canvasBackground: CanvasBackground = .color(.white)
    @State private var showBackgroundSheet = false
    @State private var bgPickerItem: PhotosPickerItem?  // still used for background only
    @State private var selectedColor: Color = .white

    // Trash zone
    @State private var showTrashZone = false
    @State private var trashIsTargeted = false

    // Music search
    @State private var showMusicSearch = false

    // Video
    @State private var showVideoPicker  = false
    @State private var pendingVideoURL: URL? = nil

    // Long-press menu
    @State private var selectedItem: PhotosPickerItem?
    @State private var showPlusMenu = false
    @State private var showPhotosPicker = false
    @State private var showTextSticker = false
    @State private var textEditTarget: TextEditTarget?

    // Undo
    @State private var undoStack: [CanvasSnapshot] = []

    // Canvas view reference for thumbnail capture
    @State private var canvasUIView: CanvasUIView?

    var body: some View {
        CanvasHostView(
                stickers: $stickers,
                selectedStickerID: $selectedStickerID,
                canvasScale: $canvasScale,
                canvasOffset: $canvasOffset,
                canvasBackground: canvasBackground,
                canvasMode: canvasMode,
                onTapEmpty: { selectedStickerID = nil },
                onTapSticker: { id in
                    selectedStickerID = id
                    bringToFront(stickerID: id)
                },
                onDragChanged: { screenPos in
                    let screenHeight = UIScreen.main.bounds.height
                    let nearBottom = screenPos.y > screenHeight - 220
                    let inZone = screenPos.y > screenHeight - 130
                    withAnimation(.spring(duration: 0.25)) {
                        showTrashZone = nearBottom
                        trashIsTargeted = inZone
                    }
                },
                onDragEnded: { screenPos, stickerID in
                    let screenHeight = UIScreen.main.bounds.height
                    if screenPos.y > screenHeight - 130 {
                        saveUndoState()
                        withAnimation(.spring(duration: 0.2)) {
                            stickers.removeAll { $0.id == stickerID }
                            if selectedStickerID == stickerID { selectedStickerID = nil }
                        }
                    }
                    withAnimation(.spring(duration: 0.3)) {
                        showTrashZone = false
                        trashIsTargeted = false
                    }
                },
                onStickerGestureStart: {
                    saveUndoState()
                },
                onTextEdit: { id in
                    if let sticker = stickers.first(where: { $0.id == id }),
                       case .text(let content) = sticker.kind {
                        textEditTarget = TextEditTarget(id: id, content: content)
                    }
                },
                onViewReady: { view in canvasUIView = view }
            )
            .ignoresSafeArea()
            .background(ShakeDetector())
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                undo()
            }
            .overlay(alignment: .bottom) {
                if showTrashZone && !coverPickerMode {
                    trashZone
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if coverPickerMode {
                    coverPickerOverlay
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                showPlusMenu = true
                            }
                        }
                }
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $selectedItem, matching: .images)
            .sheet(isPresented: $showMusicSearch) {
                MusicSearchView(
                    onSelect: { track in
                        addMusicSticker(track: track)
                        showMusicSearch = false
                    },
                    onCancel: { showMusicSearch = false }
                )
                .presentationDetents([.medium, .large])
            }
            .overlay {
                if showPlusMenu {
                    PlusMenuOverlay(
                        onSelect: { item in
                            showPlusMenu = false
                            switch item {
                            case .photo:      showPhotosPicker = true
                            case .text:       showTextSticker = true
                            case .background: showBackgroundSheet = true
                            case .music:      showMusicSearch = true
                            case .video:      showVideoPicker = true
                            }
                        },
                        onDismiss: { showPlusMenu = false }
                    )
                }
            }
            .sheet(isPresented: $showVideoPicker) {
                VideoPicker { url in
                    pendingVideoURL = url
                    showVideoPicker = false
                }
            }
            .sheet(item: $pendingVideoURL) { url in
                VideoProcessingView(
                    videoURL: url,
                    onComplete: { result in
                        pendingVideoURL = nil
                        addVideoSticker(result: result)
                    },
                    onCancel: {
                        pendingVideoURL = nil
                    }
                )
            }
            .onChange(of: selectedItem) { _, newItem in
                guard let newItem else { return }
                Task { await addStickerFromImage(from: newItem) }
            }
            .onChange(of: bgPickerItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadBackgroundImage(from: newItem) }
            }
            .sheet(isPresented: $showTextSticker) {
                TextStickerSheet(
                    onAdd: { content in
                        showTextSticker = false
                        saveUndoState()
                        topZ += 1
                        let sticker = Sticker(
                            kind: .text(content),
                            position: visibleCenter(),
                            scale: 1.0,
                            rotation: .zero,
                            zIndex: topZ
                        )
                        stickers.append(sticker)
                        selectedStickerID = sticker.id
                    },
                    onCancel: { showTextSticker = false }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $textEditTarget) { target in
                TextStickerSheet(
                    initialContent: target.content,
                    onAdd: { newContent in
                        if let idx = stickers.firstIndex(where: { $0.id == target.id }) {
                            saveUndoState()
                            stickers[idx].kind = .text(newContent)
                        }
                        textEditTarget = nil
                    },
                    onCancel: { textEditTarget = nil }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showBackgroundSheet) {
                backgroundSheet
            }
            .onAppear  { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { loadCanvas() } }
            .onDisappear { saveCanvas() }
    }

    // MARK: - Canvas Persistence

    private func loadCanvas() {
        guard let json = initialCanvasData,
              let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(CanvasState.self, from: data) else { return }

        // Background
        switch state.background.type {
        case "image":
            if let fn = state.background.imageFilename,
               let img = StickerStorage.loadImage(filename: fn) {
                canvasBackground = .image(img)
            }
        default:
            if let c = state.background.colorComponents, c.count == 4 {
                canvasBackground = .color(UIColor(red: c[0], green: c[1], blue: c[2], alpha: c[3]))
            }
        }

        // Stickers
        var loaded: [Sticker] = []
        for s in state.stickers {
            let pos = CGPoint(x: s.x, y: s.y)
            let rot = Angle(radians: s.rotationRadians)
            switch s.type {
            case "photo":
                if let fn = s.imageFilename, let img = StickerStorage.loadImage(filename: fn) {
                    loaded.append(Sticker(id: s.id, kind: .photo(img), position: pos, scale: s.scale, rotation: rot, zIndex: s.zIndex))
                }
            case "text":
                if let text = s.textString, let fi = s.fontIndex, let ci = s.colorIndex {
                    let content = TextStickerContent(text: text, fontIndex: fi, colorIndex: ci)
                    loaded.append(Sticker(id: s.id, kind: .text(content), position: pos, scale: s.scale, rotation: rot, zIndex: s.zIndex))
                }
            case "music":
                if let mid = s.musicID, let title = s.musicTitle, let artist = s.musicArtist {
                    var track = MusicTrack(
                        id: mid, title: title, artistName: artist,
                        artworkURL: s.musicArtworkURLString.flatMap { URL(string: $0) },
                        previewURL: s.musicPreviewURLString.flatMap { URL(string: $0) }
                    )
                    // Restore cached artwork — no network call needed
                    if let artFn = s.musicArtworkImageFilename {
                        track.artworkImage = StickerStorage.loadImage(filename: artFn)
                    }
                    loaded.append(Sticker(id: s.id, kind: .music(track), position: pos, scale: s.scale, rotation: rot, zIndex: s.zIndex))
                }
            case "video":
                if let vfn = s.videoFilename,
                   let videoURL = StickerStorage.loadVideoURL(filename: vfn),
                   let tfn = s.videoThumbnailFilename,
                   let thumb = StickerStorage.loadImage(filename: tfn) {
                    loaded.append(Sticker(id: s.id, kind: .video(videoURL: videoURL, thumbnail: thumb, bgRemoved: s.bgRemoved ?? false), position: pos, scale: s.scale, rotation: rot, zIndex: s.zIndex))
                }
            default: break
            }
        }
        stickers = loaded
        topZ = loaded.map { $0.zIndex }.max() ?? 0
    }

    private func saveCanvas() {
        // Cover-picker mode is read-only; skip entirely.
        guard let tid = tapestryID, !coverPickerMode else { return }

        // Snapshot value types so the background task owns its own copies
        let stickerSnapshot    = stickers
        let backgroundSnapshot = canvasBackground

        Task.detached(priority: .utility) { [store] in
            var stickerStates: [StickerState] = []
            for sticker in stickerSnapshot {
                var s = StickerState(
                    id: sticker.id, type: "",
                    x: sticker.position.x, y: sticker.position.y,
                    scale: sticker.scale,
                    rotationRadians: sticker.rotation.radians,
                    zIndex: sticker.zIndex
                )
                switch sticker.kind {
                case .photo(let img):
                    s.type = "photo"
                    if img.images != nil {
                        s.imageFilename = "\(sticker.id.uuidString).gif"
                    } else {
                        let fn = "\(sticker.id.uuidString).png"
                        StickerStorage.saveImage(img, filename: fn)
                        s.imageFilename = fn
                    }
                case .text(let content):
                    s.type = "text"
                    s.textString = content.text
                    s.fontIndex   = content.fontIndex
                    s.colorIndex  = content.colorIndex
                case .music(let track):
                    s.type = "music"
                    s.musicID               = track.id
                    s.musicTitle            = track.title
                    s.musicArtist           = track.artistName
                    s.musicArtworkURLString = track.artworkURL?.absoluteString
                    s.musicPreviewURLString = track.previewURL?.absoluteString
                    if let artImg = track.artworkImage {
                        let artFn = "\(sticker.id.uuidString)_art.png"
                        StickerStorage.saveImage(artImg, filename: artFn)
                        s.musicArtworkImageFilename = artFn
                    }
                case .video(let url, let thumb, let bgRemoved):
                    s.type = "video"
                    let vfn = "\(sticker.id.uuidString).mp4"
                    let tfn = "\(sticker.id.uuidString)_thumb.png"
                    StickerStorage.saveVideo(from: url, filename: vfn)
                    StickerStorage.saveImage(thumb, filename: tfn)
                    s.videoFilename          = vfn
                    s.videoThumbnailFilename = tfn
                    s.bgRemoved              = bgRemoved
                }
                stickerStates.append(s)
            }

            // Background state
            var bgState = CanvasState.BackgroundState(type: "color")
            switch backgroundSnapshot {
            case .color(let c):
                bgState.type = "color"
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                bgState.colorComponents = [r, g, b, a].map { Double($0) }
            case .image(let img):
                bgState.type = "image"
                let fn = "\(tid.uuidString)_bg.png"
                StickerStorage.saveImage(img, filename: fn)
                bgState.imageFilename = fn
            }

            guard let data = try? JSONEncoder().encode(CanvasState(background: bgState, stickers: stickerStates)),
                  let json = String(data: data, encoding: .utf8) else { return }

            await MainActor.run { store.updateCanvas(tapestryID: tid, canvasJSON: json) }
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
                            canvasBackground = .color(UIColor(newColor))
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
        VStack(spacing: 0) {
            // Top banner — taps here are consumed; canvas underneath remains interactive
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
                // Invisible balance spacer so title stays centred
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial.opacity(0.85))

            // Middle — let all touches fall through to the canvas
            Spacer()
                .allowsHitTesting(false)

            // Bottom — checkmark confirm
            Button {
                guard let tid = tapestryID,
                      let img = canvasUIView?.renderViewportThumbnail() else { return }
                // Save directly from within the canvas — store is in scope via @Environment
                if let filename = store.saveThumbnail(img, for: tid) {
                    store.updateThumbnailFilename(tapestryID: tid, filename: filename)
                }
                onCoverPicked?(img)   // signal parent to dismiss
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
        .ignoresSafeArea()
    }

    // MARK: - Sticker Management

    @MainActor
    private func addStickerFromImage(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }

        let stickerID = UUID()
        let uiImage: UIImage

        if data.isAnimatedGIF, let animated = UIImage.animatedGIF(from: data) {
            uiImage = animated
            // Persist raw GIF bytes immediately so saveCanvas can reference them by ID
            let fn = "\(stickerID.uuidString).gif"
            Task.detached(priority: .utility) { StickerStorage.saveGIF(data, filename: fn) }
        } else {
            guard let img = UIImage(data: data)?.normalized() else { return }
            uiImage = img
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
        withAnimation(.spring(duration: 0.25)) {
            stickers = snapshot.stickers
            topZ = snapshot.topZ
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func bringToFront(stickerID: UUID) {
        guard let idx = stickers.firstIndex(where: { $0.id == stickerID }) else { return }
        topZ += 1
        stickers[idx].zIndex = topZ
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

// MARK: - Text Edit Target

private struct TextEditTarget: Identifiable {
    let id: UUID                 // sticker ID
    let content: TextStickerContent
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

struct Sticker: Identifiable {
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
    let onTextEdit: (UUID) -> Void
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
        context.coordinator.onTextEdit = onTextEdit

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

    /// Renders the currently visible viewport (what the user sees) to a square UIImage.
    /// Used for the "Edit Cover" screenshot capture.
    func renderViewportThumbnail() -> UIImage? {
        // Hide the grid for a clean capture
        let gridWasHidden = gridLayer.isHidden
        gridLayer.isHidden = true

        let side = min(bounds.width, bounds.height)
        let captureRect = CGRect(
            x: (bounds.width  - side) / 2,
            y: (bounds.height - side) / 2,
            width: side, height: side
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

    /// Renders the full canvas content to a square thumbnail (window into the tapestry).
    func renderThumbnail(size: CGFloat = 600) -> UIImage? {
        let targetSize = CGSize(width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0   // 1200px output — crisp on all devices, renders ~3× faster than 3×
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        // Temporarily hide grid and deselect visually
        let gridWasHidden = gridLayer.isHidden
        gridLayer.isHidden = true

        let image = renderer.image { ctx in
            let s = targetSize.width / canvasView.bounds.width
            ctx.cgContext.scaleBy(x: s, y: s)
            canvasView.layer.render(in: ctx.cgContext)
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
            self.coordinator?.canvasPan?.isEnabled   = true
            self.coordinator?.canvasPinch?.isEnabled = true
            self.applyLasso(points: points, stickerID: stickerID)
        }
        overlay.onCancel = { [weak self] in
            UIView.animate(withDuration: 0.2) { overlay.alpha = 0 } completion: { _ in
                overlay.removeFromSuperview()
            }
            self?.lassoOverlay = nil
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

    func syncStickersIfNeeded(stickers: [Sticker], selectedID: UUID?) {
        // Skip if nothing changed — e.g. pure pan/pinch updates
        let stickersSame  = lastSyncedStickers.map { $0.elementsEqual(stickers, by: { $0.id == $1.id && $0.position == $1.position && $0.scale == $1.scale && $0.rotation == $1.rotation && $0.zIndex == $1.zIndex }) } ?? false
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
                    sc.onGestureEnd = gestureEnd
                    sc.onDragChanged = { [weak coordinator] p in coordinator?.onDragChanged?(p) }
                    sc.onDragEnded   = { [weak coordinator] p in coordinator?.onDragEnded?(p, sid) }
                    sc.onDoubleTap   = { [weak coordinator] in coordinator?.onDoubleTap?(sid) }
                    let sv = StickerUIView(coordinator: sc)
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
                    sc.onGestureEnd = gestureEnd
                    sc.onDragChanged = { [weak coordinator] p in coordinator?.onDragChanged?(p) }
                    sc.onDragEnded   = { [weak coordinator] p in coordinator?.onDragEnded?(p, sid) }
                    sc.onLongPress   = { [weak coordinator] in
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
                    mc.onGestureEnd = gestureEnd
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
                    vc.onGestureEnd = gestureEnd
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
    var onTextEdit: ((UUID) -> Void)?
    var onDoubleTap: ((UUID) -> Void)?
    weak var canvasView: UIView?
    weak var canvasPan: UIPanGestureRecognizer?
    weak var canvasPinch: UIPinchGestureRecognizer?

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

