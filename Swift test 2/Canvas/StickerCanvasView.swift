import SwiftUI
import PhotosUI
import UIKit

// MARK: - StickerCanvasView

struct StickerCanvasView: View {
    var tapestryID: UUID? = nil
    var initialCanvasData: String? = nil
    var canvasMode: CanvasMode = .infinite
    var coverPickerMode: Bool = false
    var coverFrameAspectRatio: CGFloat = 1.0
    var onCoverPicked: ((UIImage) -> Void)? = nil
    var onCoverCancelled: (() -> Void)? = nil
    var isCollaborative: Bool = false
    var isOwner: Bool = true
    var onDismiss: (() -> Void)? = nil

    @Environment(TapestryStore.self) private var store
    @Environment(AuthManager.self)   private var auth
    @Environment(\.colorScheme)      private var colorScheme
    @Environment(\.scenePhase)       private var scenePhase

    // ViewModel — initialized in onAppear once store is available
    @State private var vm: CanvasViewModel?

    // MARK: UI-only state (sheets, pickers, overlays)

    @State private var showBackgroundSheet   = false
    @State private var bgPickerItem:          PhotosPickerItem?
    @State private var selectedColor:         Color = .white

    @State private var showTrashZone  = false
    @State private var trashIsTargeted = false

    @State private var showMusicSearch = false
    @State private var showVideoPicker = false
    @State private var pendingVideoURL: URL? = nil

    @State private var showCameraMenu    = false
    @State private var showCameraCapture = false

    @State private var selectedItem:   PhotosPickerItem?
    @State private var showPlusMenu    = false
    @State private var showPhotosPicker = false

    @State private var showTextEditor       = false
    @State private var textEditorContent:   TextStickerContent? = nil
    @State private var textEditorTargetID:  UUID?               = nil

    @State private var showLayersPanel = false

    @State private var isGeneratingInvite = false
    @State private var pendingInviteToken: String? = nil
    @State private var inviteError: String? = nil

    // MARK: - Body

    var body: some View {
        ZStack {
            if let vm {
                @Bindable var vm = vm
                canvasWithPickerSheets(vm: vm)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbarContent(vm: vm) }
                    .sheet(isPresented: Binding(
                        get: { vm.pendingInviteToken != nil },
                        set: { if !$0 { vm.pendingInviteToken = nil } }
                    )) {
                        if let token = vm.pendingInviteToken {
                            InviteShareSheet(token: token).presentationDetents([.height(320)])
                        }
                    }
                    .onDisappear { vm.teardown() }
                    .onChange(of: vm.stickers) { _, _ in
                        vm.saveCanvasLocalBackup()
                        vm.scheduleAutosave()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .background { vm.handleAppBackground() }
                    }
                    .alert("Tapestry Deleted", isPresented: $vm.showTapestryDeletedAlert) {
                        Button("OK") { onDismiss?() }
                    } message: {
                        Text("The owner has deleted this tapestry.")
                    }
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .onAppear {
            guard vm == nil else { return }
            vm = CanvasViewModel(
                store: store,
                tapestryID: tapestryID,
                initialCanvasData: initialCanvasData,
                canvasMode: canvasMode,
                coverPickerMode: coverPickerMode,
                isCollaborative: isCollaborative,
                isOwner: isOwner
            )
            Task { await vm?.startCanvas() }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(vm: CanvasViewModel) -> some ToolbarContent {
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
            ToolbarItem(placement: .topBarTrailing) { inviteButton(vm: vm) }
        }
    }

    // MARK: - Canvas layers

    private func canvasWithPickerSheets(vm: CanvasViewModel) -> some View {
        @Bindable var vm = vm
        return canvasContent(vm: vm)
            .photosPicker(isPresented: $showPhotosPicker, selection: $selectedItem, matching: .images)
            .sheet(isPresented: $showMusicSearch) {
                MusicSearchView(
                    onSelect: { track in vm.addMusicSticker(track: track); showMusicSearch = false },
                    onCancel: { showMusicSearch = false }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showVideoPicker) {
                VideoPicker { url in pendingVideoURL = url; showVideoPicker = false }
            }
            .fullScreenCover(isPresented: $showCameraCapture) {
                CameraCapturePicker(
                    onCapture: { image in showCameraCapture = false; vm.addStickerFromCapturedImage(image) },
                    onCancel: { showCameraCapture = false }
                ).ignoresSafeArea()
            }
            .sheet(item: $pendingVideoURL) { url in
                VideoProcessingView(
                    videoURL: url,
                    onComplete: { result in pendingVideoURL = nil; vm.addVideoSticker(result: result) },
                    onCancel: { pendingVideoURL = nil }
                )
            }
            .sheet(isPresented: $showBackgroundSheet) { backgroundSheet(vm: vm) }
            .onChange(of: selectedItem) { _, newItem in
                guard let newItem else { return }
                Task { await vm.addStickerFromImage(from: newItem); selectedItem = nil }
            }
            .onChange(of: bgPickerItem) { _, newItem in
                guard let newItem else { return }
                Task { await vm.loadBackgroundImage(from: newItem); bgPickerItem = nil; showBackgroundSheet = false }
            }
            .overlay { if showPlusMenu { plusMenuOverlay(vm: vm) } }
            .overlay(alignment: .leading) { if showLayersPanel { layersPanelOverlay(vm: vm) } }
            .overlay { if showCameraMenu { cameraMenuOverlay } }
            .overlay { if showTextEditor { textEditorOverlay(vm: vm) } }
    }

    private func canvasContent(vm: CanvasViewModel) -> some View {
        @Bindable var vm = vm
        return CanvasHostView(
            stickers: $vm.stickers,
            selectedStickerID: $vm.selectedStickerID,
            canvasScale: $vm.canvasScale,
            canvasOffset: $vm.canvasOffset,
            canvasBackground: vm.canvasBackground,
            canvasMode: canvasMode,
            onTapEmpty: {
                vm.selectedStickerID = nil
                if showLayersPanel {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showLayersPanel = false }
                }
            },
            onTapSticker: { id in
                vm.selectedStickerID = id
                vm.bringToFront(stickerID: id)
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
                    vm.deleteSticker(id: stickerID)
                } else if let session = vm.collabSession,
                          let s = vm.stickers.first(where: { $0.id == stickerID }) {
                    session.broadcast(session.opMove(stickerID: stickerID, x: s.position.x, y: s.position.y))
                }
                withAnimation(.spring(duration: 0.3)) { showTrashZone = false; trashIsTargeted = false }
            },
            onStickerGestureStart: { vm.saveUndoState() },
            onStickerGestureEnded: { id in vm.broadcastGestureEnded(stickerID: id) },
            onTextEdit: { id in
                guard let sticker = vm.stickers.first(where: { $0.id == id }),
                      case .text(let content) = sticker.kind else { return }
                textEditorContent = content
                textEditorTargetID = id
                withAnimation { showTextEditor = true }
            },
            onPhotoReplaced: { id, img in vm.broadcastPhotoReplaced(stickerID: id, image: img) },
            onViewReady: { view in vm.canvasUIView = view }
        )
        .ignoresSafeArea()
        .background(ShakeDetector())
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in vm.undo() }
        .overlay(alignment: .bottom) {
            if showTrashZone && !coverPickerMode {
                trashZone.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay { if coverPickerMode { coverPickerOverlay(vm: vm) } }
    }

    // MARK: - Toolbar Buttons

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

    private func inviteButton(vm: CanvasViewModel) -> some View {
        Button {
            guard let uid = auth.userID, let tid = tapestryID else { return }
            isGeneratingInvite = true
            Task {
                do {
                    let token = try await InviteService.getOrCreateCode(tapestryID: tid, userID: uid)
                    await MainActor.run { vm.pendingInviteToken = token; isGeneratingInvite = false }
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

    // MARK: - Overlays

    private func plusMenuOverlay(vm: CanvasViewModel) -> some View {
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

    private func layersPanelOverlay(vm: CanvasViewModel) -> some View {
        LayersPanelView(
            stickers: vm.stickers,
            onSelect: { id in vm.selectedStickerID = id; vm.bringToFront(stickerID: id) },
            onDismiss: { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showLayersPanel = false } },
            onReorder: { orderedIDs in
                vm.saveUndoState()
                for (position, id) in orderedIDs.enumerated() {
                    if let idx = vm.stickers.firstIndex(where: { $0.id == id }) {
                        let z = Double(orderedIDs.count - position)
                        vm.stickers[idx].zIndex = z
                        vm.collabSession.map { $0.broadcast($0.opReorder(stickerID: id, zIndex: z)) }
                    }
                }
            }
        )
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private func textEditorOverlay(vm: CanvasViewModel) -> some View {
        TextEditorOverlay(
            initialContent: textEditorContent,
            onComplete: { content in
                withAnimation { showTextEditor = false }
                if let targetID = textEditorTargetID {
                    vm.updateTextSticker(id: targetID, content: content)
                } else {
                    vm.addTextSticker(content: content)
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

    // MARK: - Background Sheet

    private func backgroundSheet(vm: CanvasViewModel) -> some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Color").font(.headline)
                    ColorPicker("Background color", selection: $selectedColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: selectedColor) { _, newColor in
                            vm.setBackgroundColor(UIColor(newColor))
                        }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                        ForEach(presetColors, id: \.self) { color in
                            Circle()
                                .fill(Color(uiColor: color))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                .onTapGesture {
                                    selectedColor = Color(uiColor: color)
                                    vm.setBackgroundColor(color)
                                }
                        }
                    }
                }
                .padding(.horizontal)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Photo").font(.headline).padding(.horizontal)
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
        .systemPink, UIColor(red: 0.95, green: 0.88, blue: 0.76, alpha: 1),
        UIColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1),
        UIColor(red: 0.85, green: 0.95, blue: 0.88, alpha: 1),
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
                .fill(trashIsTargeted ? Color.red.opacity(0.35) : Color.black.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(trashIsTargeted ? Color.red.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    // MARK: - Cover Picker Overlay

    private func coverPickerOverlay(vm: CanvasViewModel) -> some View {
        GeometryReader { geo in
            let ar     = coverFrameAspectRatio
            let frameW = min(geo.size.width, geo.size.height * ar)
            let frameH = frameW / ar
            let xInset = (geo.size.width  - frameW) / 2
            let yInset = (geo.size.height - frameH) / 2
            let frameRect = CGRect(x: xInset, y: yInset, width: frameW, height: frameH)

            ZStack(alignment: .top) {
                CoverFrameMask(frameRect: frameRect, size: geo.size)
                    .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                    .frame(width: frameW, height: frameH)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .allowsHitTesting(false)

                CornerTicks(rect: frameRect)
                    .stroke(.white, lineWidth: 3)
                    .allowsHitTesting(false)

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

                VStack {
                    Spacer()
                    Button {
                        guard let tid = tapestryID, let cv = vm.canvasUIView else {
                            onCoverCancelled?(); return
                        }
                        let ar = coverFrameAspectRatio
                        let capW = min(cv.bounds.width, cv.bounds.height * ar)
                        let capH = capW / ar
                        let captureRect = CGRect(
                            x: (cv.bounds.width  - capW) / 2,
                            y: (cv.bounds.height - capH) / 2,
                            width: capW, height: capH
                        )
                        guard let img = cv.renderViewportThumbnail(in: captureRect) else {
                            onCoverCancelled?(); return
                        }
                        if let filename = store.saveThumbnail(img, for: tid) {
                            store.updateThumbnailFilename(tapestryID: tid, filename: filename)
                        }
                        onCoverPicked?(img)
                    } label: {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 64, height: 64)
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

private struct CoverFrameMask: Shape {
    let frameRect: CGRect
    let size: CGSize

    func path(in _: CGRect) -> Path {
        var p = Path(CGRect(origin: .zero, size: size))
        p.addRoundedRect(in: frameRect, cornerRadii: .init(topLeading: 16, bottomLeading: 16, bottomTrailing: 16, topTrailing: 16))
        return p
    }
}

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

