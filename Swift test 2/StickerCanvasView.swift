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

    // Undo
    @State private var undoStack: [CanvasSnapshot] = []


    var body: some View {
        NavigationStack {
            CanvasHostView(
                stickers: $stickers,
                selectedStickerID: $selectedStickerID,
                canvasScale: $canvasScale,
                canvasOffset: $canvasOffset,
                canvasBackground: canvasBackground,
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
                }
            )
            .ignoresSafeArea()
            .background(ShakeDetector())
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                undo()
            }
            .overlay(alignment: .bottom) {
                if showTrashZone {
                    trashZone
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // PhotosPicker handles the tap naturally.
                    // A DragGesture sits alongside it — dragging down
                    // opens the menu without interfering with the tap.
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 10, coordinateSpace: .global)
                            .onChanged { value in
                                guard !showPlusMenu else { return }
                                let dy = value.translation.height
                                let dx = abs(value.translation.width)
                                // Only trigger on a clearly downward drag
                                if dy > 18 && dy > dx * 1.5 {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        showPlusMenu = true
                                    }
                                }
                            }
                    )
                }
            }
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
            .sheet(isPresented: $showBackgroundSheet) {
                backgroundSheet
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

    // MARK: - Sticker Management

    @MainActor
    private func addStickerFromImage(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data)?.normalized()
        else { return }
        saveUndoState()
        topZ += 1
        let sticker = Sticker(
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
    case music(MusicTrack)
    case video(videoURL: URL, thumbnail: UIImage, bgRemoved: Bool = false)
}

struct Sticker: Identifiable {
    let id = UUID()
    var kind: StickerKind
    var position: CGPoint
    var scale: CGFloat
    var rotation: Angle
    var zIndex: Double = 0

    // Convenience accessors
    var image: UIImage? {
        if case .photo(let img) = kind { return img }
        return nil
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
    let onTapEmpty: () -> Void
    let onTapSticker: (UUID) -> Void
    let onDragChanged: (CGPoint) -> Void        // screen pos while dragging any sticker
    let onDragEnded: (CGPoint, UUID) -> Void    // screen pos + id on release
    let onStickerGestureStart: () -> Void

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
        CanvasUIView(coordinator: context.coordinator)
    }

    func updateUIView(_ view: CanvasUIView, context: Context) {
        context.coordinator.stickers = $stickers
        context.coordinator.selectedStickerID = $selectedStickerID
        context.coordinator.onTapEmpty = onTapEmpty
        context.coordinator.onTapSticker = onTapSticker
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onStickerGestureStart = onStickerGestureStart

        view.syncBackground(canvasBackground)
        view.syncStickers(
            stickers: stickers,
            selectedID: selectedStickerID,
            canvasScale: canvasScale,
            canvasOffset: canvasOffset
        )
    }
}

// MARK: - CanvasUIView

final class CanvasUIView: UIView {
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

    init(coordinator: CanvasCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        backgroundColor = UIColor.systemBackground

        canvasView.frame = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        canvasView.backgroundColor = .clear
        addSubview(canvasView)

        // Background color fill
        backgroundColorView.frame = canvasView.bounds
        backgroundColorView.backgroundColor = .white
        canvasView.addSubview(backgroundColorView)

        // Background image (hidden until set)
        backgroundImageView.frame = canvasView.bounds
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.isHidden = true
        canvasView.addSubview(backgroundImageView)

        gridLayer.frame = canvasView.bounds
        gridLayer.backgroundColor = .clear
        canvasView.addSubview(gridLayer)

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleCanvasPan))
        pan.delegate = coordinator
        coordinator.canvasPan = pan
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleCanvasPinch))
        pinch.delegate = coordinator
        coordinator.canvasPinch = pinch
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleCanvasTap))
        tap.delegate = coordinator
        addGestureRecognizer(tap)

        coordinator.canvasView = canvasView
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.centerCanvasIfNeeded(in: bounds)
    }


    func syncBackground(_ background: CanvasBackground) {
        switch background {
        case .color(let color):
            backgroundColorView.backgroundColor = color
            backgroundColorView.isHidden = false
            backgroundImageView.isHidden = true
            gridLayer.isHidden = false
        case .image(let image):
            backgroundImageView.image = image
            backgroundImageView.isHidden = false
            backgroundColorView.isHidden = true
            gridLayer.isHidden = true   // hide grid over photo backgrounds
        }
    }

    func syncStickers(stickers: [Sticker], selectedID: UUID?, canvasScale: CGFloat, canvasOffset: CGSize) {
        guard let coordinator else { return }

        canvasView.transform = CGAffineTransform(scaleX: canvasScale, y: canvasScale)
        canvasView.center = CGPoint(
            x: bounds.midX + canvasOffset.width,
            y: bounds.midY + canvasOffset.height
        )

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

