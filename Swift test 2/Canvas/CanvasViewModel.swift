import SwiftUI
import PhotosUI

// MARK: - StickerDeserialization

/// Returned by deserializeSticker(from:) so callers can cache URLs on the main actor.
private struct StickerDeserialization {
    let sticker:      Sticker
    let uploadedURL:  String?   // image/video URL to cache in uploadedURLs
    let thumbnailURL: String?   // video thumbnail URL to cache in uploadedThumbnailURLs
}

// MARK: - CanvasSnapshot

struct CanvasSnapshot {
    let stickers: [Sticker]
    let topZ: Double
}

// MARK: - CanvasViewModel
//
// Holds all canvas state and business logic extracted from StickerCanvasView.
// Marked @MainActor to match the implicit isolation of the SwiftUI view methods it
// replaced — Task(priority:) closures inside still suspend cooperatively and allow
// async work (uploads, downloads) to run on background threads via await.

@Observable
@MainActor
final class CanvasViewModel {

    // MARK: - Config (set once at init, never changes)

    let tapestryID: UUID?
    let initialCanvasData: String?
    let canvasMode: CanvasMode
    let coverPickerMode: Bool
    let isCollaborative: Bool
    let isOwner: Bool
    let isReadOnly: Bool
    private let store: TapestryStore

    // MARK: - Canvas state (drives CanvasHostView bindings)

    var stickers:          [Sticker]       = []
    var selectedStickerID: UUID?
    var topZ:              Double          = 0
    var canvasScale:       CGFloat         = 1.0
    var canvasOffset:      CGSize          = .zero
    var canvasBackground:  CanvasBackground = .color(.white)

    // MARK: - Upload caches

    var uploadedURLs:          [UUID: String] = [:]
    var uploadedThumbnailURLs: [UUID: String] = [:]

    // MARK: - System state

    var canvasLoaded:             Bool                    = false
    var isLoadingAssets:          Bool                    = false
    var showTapestryDeletedAlert: Bool                    = false
    var collabSession:            TapestryCollabSession?  = nil
    var canvasUIView:             CanvasUIView?           = nil
    var pendingInviteToken:       String?                 = nil

    // MARK: - Private

    private var undoStack:           [CanvasSnapshot]       = []
    private var autosaveTask:        Task<Void, Never>?     = nil
    private var pendingUploadTasks:  [UUID: Task<Void, Never>] = [:]
    private var pendingRemoteOps:    [UUID: [StickerOp]]       = [:]
    // Tracks the highest photo generation seen per sticker on the receive path,
    // so out-of-order / duplicate opUpdatePhoto broadcasts don't overwrite the cutout.
    private var photoGenerations:    [UUID: Int]               = [:]
    // Tracks the generation we've broadcast for each sticker on the send path.
    private var broadcastPhotoGenerations: [UUID: Int]         = [:]

    // MARK: - Init

    init(
        store: TapestryStore,
        tapestryID: UUID?,
        initialCanvasData: String?,
        canvasMode: CanvasMode,
        coverPickerMode: Bool,
        isCollaborative: Bool,
        isOwner: Bool,
        isReadOnly: Bool = false
    ) {
        self.store             = store
        self.tapestryID        = tapestryID
        self.initialCanvasData = initialCanvasData
        self.canvasMode        = canvasMode
        self.coverPickerMode   = coverPickerMode
        self.isCollaborative   = isCollaborative
        self.isOwner           = isOwner
        self.isReadOnly        = isReadOnly
    }

    // MARK: - Lifecycle

    func startCanvas() async {
        try? await Task.sleep(for: .milliseconds(50))
        await loadCanvas()
        guard isCollaborative, let tid = tapestryID, let uid = store.currentUserID else { return }
        let session = TapestryCollabSession(tapestryID: tid, senderID: uid)
        collabSession = session
        session.onOpReceived    = { [weak self] op in self?.applyRemoteOp(op) }
        session.onTapestryDeleted = { [weak self] in self?.showTapestryDeletedAlert = true }
        await session.start()
    }

    /// Called from onDisappear — cancels autosave, ends collab session, flushes saves.
    func teardown() {
        autosaveTask?.cancel()
        autosaveTask = nil
        if let session = collabSession {
            collabSession = nil
            Task { await session.end() }
        }
        saveCanvasLocalBackup()
        saveCanvas()
    }

    /// Called when the app moves to background — flush immediately without debounce.
    func handleAppBackground() {
        autosaveTask?.cancel()
        autosaveTask = nil
        saveCanvasLocalBackup()
        saveCanvas()
    }

    // MARK: - Autosave

    func scheduleAutosave() {
        guard canvasLoaded, tapestryID != nil, !coverPickerMode else { return }
        // During collab, only the owner autosaves. Members rely on per-op broadcasts
        // for live sync — having multiple writers causes race conditions where one
        // user's snapshot overwrites another's.
        if collabSession != nil && !isOwner { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveCanvas()
        }
    }

    // MARK: - Local Backup

    func localBackupURL(for tid: UUID) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(tid.uuidString)_canvas.json")
    }

    /// Writes the canvas layout to a local JSON file immediately (synchronous, no uploads).
    /// Acts as a safety net against app kills before the debounced Supabase write completes.
    func saveCanvasLocalBackup() {
        guard let tid = tapestryID, canvasLoaded, !coverPickerMode else { return }
        if collabSession != nil && !isOwner { return }

        let bgState = CanvasSerializer.serializeBackground(canvasBackground)
        let stickerStates = stickers.compactMap {
            CanvasSerializer.serializeSticker($0, uploadedURLs: uploadedURLs,
                                              uploadedThumbnailURLs: uploadedThumbnailURLs)
        }
        guard let data = try? JSONEncoder().encode(CanvasState(background: bgState, stickers: stickerStates)) else { return }
        try? data.write(to: localBackupURL(for: tid))
    }

    // MARK: - Load Canvas

    func loadCanvas() async {
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
                    if localState.stickers.count > remoteState.stickers.count {
                        sourceJSON = String(data: backupData, encoding: .utf8)
                    }
                } else if sourceJSON == nil {
                    sourceJSON = String(data: backupData, encoding: .utf8)
                }
            }
        }

        guard let json = sourceJSON,
              let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(CanvasState.self, from: data) else {
            canvasLoaded = true
            return
        }

        // Background: apply color synchronously; fetch background image in a background Task
        // so it doesn't block the canvas from appearing.
        switch state.background.type {
        case "image":
            if let urlString = state.background.imageURL {
                Task {
                    guard let localURL = try? await StickerAssetUploader.cachedLocalURL(for: urlString, ext: "png"),
                          let img = UIImage(contentsOfFile: localURL.path) else { return }
                    canvasBackground = .image(img)
                }
            }
        case "live_scene":
            if let name = state.background.sceneName, let scene = LiveBackgroundScene(rawValue: name) {
                canvasBackground = .liveScene(scene)
            }
        default:
            if let c = state.background.colorComponents, c.count == 4 {
                canvasBackground = .color(UIColor(red: c[0], green: c[1], blue: c[2], alpha: c[3]))
            }
        }

        // Pass 1 (synchronous, ~0 ms): deserialize text/music inline; for photos check the disk
        // cache and either load immediately or show a .photoLoading placeholder; enqueue videos
        // and uncached photos for async download in Pass 2.
        var initialStickers: [Sticker] = []
        var downloadQueue:   [StickerState] = []

        for s in state.stickers {
            let pos = CGPoint(x: s.x, y: s.y)
            let rot = Angle(radians: s.rotationRadians)

            switch s.type {
            case StickerTypeKey.text:
                guard let content = TextStickerContent.deserialize(
                    textString: s.textString, fontIndex: s.fontIndex, colorIndex: s.colorIndex,
                    wrapWidth: s.textWrapWidth, alignment: s.textAlignment, bgStyle: s.textBGStyle
                ) else { continue }
                initialStickers.append(Sticker(id: s.id, kind: .text(content), position: pos,
                                               scale: s.scale, rotation: rot, zIndex: s.zIndex))

            case StickerTypeKey.music:
                guard let mid = s.musicID, let title = s.musicTitle, let artist = s.musicArtist else { continue }
                let track = MusicTrack(id: mid, title: title, artistName: artist,
                    artworkURL: s.musicArtworkURLString.flatMap { URL(string: $0) },
                    previewURL: s.musicPreviewURLString.flatMap { URL(string: $0) })
                initialStickers.append(Sticker(id: s.id, kind: .music(track), position: pos,
                                               scale: s.scale, rotation: rot, zIndex: s.zIndex))

            case StickerTypeKey.photo:
                var added = false
                if let urlString = s.imageURL {
                    let ext      = StickerAssetUploader.ext(for: urlString)
                    let cacheURL = StickerAssetUploader.cacheFileURL(for: urlString, ext: ext)
                    if FileManager.default.fileExists(atPath: cacheURL.path) {
                        let img = ext == "gif"
                            ? UIImage.animatedGIF(from: cacheURL)
                            : UIImage(contentsOfFile: cacheURL.path)
                        if let img {
                            initialStickers.append(Sticker(id: s.id, kind: .photo(img), position: pos,
                                                           scale: s.scale, rotation: rot, zIndex: s.zIndex))
                            uploadedURLs[s.id] = urlString
                            added = true
                        }
                    }
                } else if let fn = s.imageFilename, let img = StickerStorage.loadImage(filename: fn) {
                    initialStickers.append(Sticker(id: s.id, kind: .photo(img), position: pos,
                                                   scale: s.scale, rotation: rot, zIndex: s.zIndex))
                    added = true
                }
                if !added {
                    // Not in cache — show placeholder immediately, stream in via Pass 2
                    initialStickers.append(Sticker(id: s.id, kind: .photoLoading, position: pos,
                                                   scale: s.scale, rotation: rot, zIndex: s.zIndex))
                    downloadQueue.append(s)
                }

            case StickerTypeKey.video:
                // No placeholder for video — a .photoLoading → .video type swap in CanvasUIView
                // causes layout artifacts. Let the sticker appear when download finishes.
                downloadQueue.append(s)

            default:
                break
            }
        }

        // Canvas appears immediately with text/music and cached photos visible.
        initialStickers.sort { $0.zIndex < $1.zIndex }
        stickers     = initialStickers
        topZ         = initialStickers.map { $0.zIndex }.max() ?? 0
        canvasLoaded = true

        // Pass 2 — two independent phases so videos never block the overlay.
        //
        // Phase A: uncached photos  → parallel download behind the loading overlay.
        //          Overlay dismisses as soon as all photos are in.
        //
        // Phase B: videos           → thumbnail downloads first so the sticker
        //          appears immediately, then the full .mp4 downloads silently in
        //          the background and upgrades the sticker to playable.
        if !downloadQueue.isEmpty {
            let photoDownloads = downloadQueue.filter { $0.type == StickerTypeKey.photo }
            let videoDownloads = downloadQueue.filter { $0.type == StickerTypeKey.video }

            // Overlay only blocks on photos (fast). Videos never hold it up.
            isLoadingAssets = !photoDownloads.isEmpty
            let pass2Start = Date()
            print("[Load] Pass 2 — \(photoDownloads.count) photo(s), \(videoDownloads.count) video(s)")

            Task {
                // ── Phase A: Photos ───────────────────────────────────────────
                if !photoDownloads.isEmpty {
                    await withTaskGroup(of: Sticker?.self) { group in
                        for s in photoDownloads {
                            group.addTask {
                                let t0 = Date()
                                guard let result = await self.deserializeSticker(from: s) else {
                                    print("[Load] ❌ photo:\(s.id.uuidString.prefix(6)) — \(String(format: "%.2f", -t0.timeIntervalSinceNow))s")
                                    return nil
                                }
                                print("[Load] ✅ photo:\(s.id.uuidString.prefix(6)) — \(String(format: "%.2f", -t0.timeIntervalSinceNow))s")
                                if let url = result.uploadedURL  { await MainActor.run { self.uploadedURLs[s.id]          = url } }
                                if let url = result.thumbnailURL { await MainActor.run { self.uploadedThumbnailURLs[s.id] = url } }
                                return result.sticker
                            }
                        }
                        for await sticker in group {
                            guard let sticker else { continue }
                            if let idx = stickers.firstIndex(where: { $0.id == sticker.id }) {
                                stickers[idx] = sticker
                            }
                            canvasUIView?.invalidateStickerCache()
                        }
                    }
                    print("[Load] Photos done — \(String(format: "%.2f", -pass2Start.timeIntervalSinceNow))s total")
                    withAnimation(.easeOut(duration: 0.35)) { isLoadingAssets = false }
                }

                // ── Phase B: Videos ───────────────────────────────────────────
                // Each video gets its own Task so they download in parallel and
                // don't block each other or the now-visible canvas.
                for s in videoDownloads {
                    Task {
                        let t0 = Date()
                        let tag = "video:\(s.id.uuidString.prefix(6))"
                        guard let vURL = s.videoURL, let tURL = s.videoThumbnailURL else { return }
                        let pos = CGPoint(x: s.x, y: s.y)
                        let rot = Angle(radians: s.rotationRadians)

                        // Step 1 — thumbnail (small PNG, arrives in <1 s)
                        guard let localThumbURL = try? await StickerAssetUploader.cachedLocalURL(for: tURL, ext: "png"),
                              let thumb = UIImage(contentsOfFile: localThumbURL.path) else {
                            print("[Load] ❌ \(tag) thumb — \(String(format: "%.2f", -t0.timeIntervalSinceNow))s")
                            return
                        }
                        print("[Load] ✅ \(tag) thumb — \(String(format: "%.2f", -t0.timeIntervalSinceNow))s")

                        // Show thumbnail as a photo sticker so the user sees something right away
                        let thumbSticker = Sticker(id: s.id, kind: .photo(thumb), position: pos,
                                                   scale: s.scale, rotation: rot, zIndex: s.zIndex)
                        stickers.append(thumbSticker)
                        stickers.sort { $0.zIndex < $1.zIndex }
                        topZ = max(topZ, s.zIndex)
                        uploadedThumbnailURLs[s.id] = tURL
                        canvasUIView?.invalidateStickerCache()

                        // Step 2 — full video (large, may take many seconds)
                        guard let localVideoURL = try? await StickerAssetUploader.cachedLocalURL(for: vURL, ext: "mp4") else {
                            print("[Load] ❌ \(tag) mp4 — \(String(format: "%.2f", -t0.timeIntervalSinceNow))s")
                            return
                        }
                        print("[Load] ✅ \(tag) mp4 — \(String(format: "%.2f", -t0.timeIntervalSinceNow))s")

                        // Upgrade thumbnail → playable video sticker
                        if let idx = stickers.firstIndex(where: { $0.id == s.id }) {
                            stickers[idx].kind = .video(videoURL: localVideoURL, thumbnail: thumb,
                                                        bgRemoved: s.bgRemoved ?? false)
                            uploadedURLs[s.id] = vURL
                            canvasUIView?.invalidateStickerCache()
                        }
                    }
                }
            }
        }

        // Artwork images are not persisted — re-fetch from artworkURL for every music sticker.
        for sticker in initialStickers {
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

    // MARK: - Save Canvas

    func saveCanvas() {
        guard let tid = tapestryID, canvasLoaded, !coverPickerMode else { return }
        if isCollaborative && !isOwner { return }
        let stickerSnapshot       = stickers
        let backgroundSnapshot    = canvasBackground
        let urlCacheSnapshot      = uploadedURLs
        let thumbURLCacheSnapshot = uploadedThumbnailURLs

        let hasMediaStickers = stickerSnapshot.contains {
            switch $0.kind { case .photo, .video: return true; default: return false }
        }
        if !hasMediaStickers {
            let immediateBG     = CanvasSerializer.serializeBackground(backgroundSnapshot)
            let immediateStates = stickerSnapshot.compactMap {
                CanvasSerializer.serializeSticker($0, uploadedURLs: [:], uploadedThumbnailURLs: [:])
            }
            if let data = try? JSONEncoder().encode(CanvasState(background: immediateBG, stickers: immediateStates)),
               let json = String(data: data, encoding: .utf8) {
                store.updateCanvas(tapestryID: tid, canvasJSON: json)
            }
        }

        Task(priority: .utility) { [store = self.store, weak self] in
            guard let self else { return }
            var bgState = CanvasSerializer.serializeBackground(backgroundSnapshot)
            if case .image(let img) = backgroundSnapshot {
                bgState.imageURL = try? await StickerAssetUploader.uploadBackground(img, tapestryID: tid)
            }
            let stickerStates = await self.uploadStickerStates(
                from: stickerSnapshot,
                tapestryID: tid,
                urlCache: urlCacheSnapshot,
                thumbCache: thumbURLCacheSnapshot
            )
            if let data = try? JSONEncoder().encode(CanvasState(background: bgState, stickers: stickerStates)),
               let json = String(data: data, encoding: .utf8) {
                await MainActor.run { store.updateCanvas(tapestryID: tid, canvasJSON: json) }
            }
        }
    }

    /// Serializes each sticker, uploading any missing remote assets, and returns the resulting states.
    /// Mutates `uploadedURLs` / `uploadedThumbnailURLs` on the main actor as uploads complete.
    private func uploadStickerStates(
        from stickers: [Sticker],
        tapestryID tid: UUID,
        urlCache: [UUID: String],
        thumbCache: [UUID: String]
    ) async -> [StickerState] {
        var stickerStates: [StickerState] = []
        for sticker in stickers {
            var s = StickerState(
                id: sticker.id, type: "",
                x: sticker.position.x, y: sticker.position.y,
                scale: sticker.scale, rotationRadians: sticker.rotation.radians,
                zIndex: sticker.zIndex
            )
            switch sticker.kind {
            case .photoLoading:
                continue  // transient remote placeholder — never serialize
            case .photo(let img):
                s.type = StickerTypeKey.photo
                s.imageFilename = img.images != nil
                    ? "\(sticker.id.uuidString).gif"
                    : "\(sticker.id.uuidString).png"
                if let cached = urlCache[sticker.id] {
                    s.imageURL = cached
                } else {
                    let url: String?
                    if img.images != nil {
                        url = try? await StickerAssetUploader.uploadGIF(stickerID: sticker.id)
                    } else {
                        url = try? await StickerAssetUploader.uploadImage(img, stickerID: sticker.id)
                    }
                    guard let url else { continue }
                    s.imageURL = url
                    await MainActor.run { self.uploadedURLs[sticker.id] = url }
                }
            case .text(let c):
                CanvasSerializer.applyText(c, to: &s)
            case .music(let t):
                CanvasSerializer.applyMusic(t, to: &s)
            case .video(let url, let thumb, let bgRemoved):
                s.type = StickerTypeKey.video; s.bgRemoved = bgRemoved
                if let cached = urlCache[sticker.id] {
                    s.videoURL = cached
                    if let cachedThumb = thumbCache[sticker.id] {
                        s.videoThumbnailURL = cachedThumb
                    } else {
                        s.videoThumbnailURL = try? await StickerAssetUploader.uploadVideoThumbnail(thumb, stickerID: sticker.id)
                        if let tURL = s.videoThumbnailURL { await MainActor.run { self.uploadedThumbnailURLs[sticker.id] = tURL } }
                    }
                } else {
                    s.videoURL = try? await StickerAssetUploader.uploadVideo(from: url, stickerID: sticker.id)
                    if let vURL = s.videoURL { await MainActor.run { self.uploadedURLs[sticker.id] = vURL } }
                    s.videoThumbnailURL = try? await StickerAssetUploader.uploadVideoThumbnail(thumb, stickerID: sticker.id)
                    if let tURL = s.videoThumbnailURL { await MainActor.run { self.uploadedThumbnailURLs[sticker.id] = tURL } }
                }
            }
            if s.type == StickerTypeKey.video && s.videoThumbnailURL == nil { continue }
            stickerStates.append(s)
        }
        return stickerStates
    }

    // MARK: - Collab: Apply Remote Ops

    func applyRemoteOp(_ op: StickerOp) {
        switch op.type {
        case .move:
            guard let x = op.x, let y = op.y else { return }
            guard let i = stickers.firstIndex(where: { $0.id == op.stickerID }) else {
                pendingRemoteOps[op.stickerID, default: []].append(op); return
            }
            stickers[i].position = CGPoint(x: x, y: y)
        case .scale:
            guard let scale = op.scale else { return }
            guard let i = stickers.firstIndex(where: { $0.id == op.stickerID }) else {
                pendingRemoteOps[op.stickerID, default: []].append(op); return
            }
            stickers[i].scale = scale
        case .rotate:
            guard let radians = op.rotationRadians else { return }
            guard let i = stickers.firstIndex(where: { $0.id == op.stickerID }) else {
                pendingRemoteOps[op.stickerID, default: []].append(op); return
            }
            stickers[i].rotation = Angle(radians: radians)
        case .add:
            guard let state = op.sticker, !stickers.contains(where: { $0.id == op.stickerID }) else { return }
            let sid = op.stickerID
            Task {
                await applyRemoteAdd(state)
                // Flush any ops that arrived before opAdd (e.g. opUpdatePhoto racing ahead)
                if let buffered = self.pendingRemoteOps.removeValue(forKey: sid) {
                    for bufferedOp in buffered { self.applyRemoteOp(bufferedOp) }
                }
            }
        case .delete:
            withAnimation(.spring(duration: 0.2)) {
                stickers.removeAll { $0.id == op.stickerID }
                if selectedStickerID == op.stickerID { selectedStickerID = nil }
            }
        case .reorder:
            guard let zIndex = op.zIndex, let i = stickers.firstIndex(where: { $0.id == op.stickerID }) else { return }
            stickers[i].zIndex = zIndex
        case .updateText:
            guard let i = stickers.firstIndex(where: { $0.id == op.stickerID }),
                  let content = TextStickerContent.deserialize(
                      textString: op.textString, fontIndex: op.fontIndex, colorIndex: op.colorIndex,
                      wrapWidth: op.textWrapWidth, alignment: op.textAlignment, bgStyle: op.textBGStyle
                  ) else { return }
            stickers[i].kind = .text(content)
            canvasUIView?.invalidateStickerCache()
        case .updatePhoto:
            guard let urlString = op.imageURL else { return }
            guard stickers.contains(where: { $0.id == op.stickerID }) else {
                // opAdd hasn't arrived yet — buffer for when it does
                pendingRemoteOps[op.stickerID, default: []].append(op)
                return
            }
            let sid = op.stickerID
            let incomingGen = op.photoGeneration ?? 0
            // Discard if we've already applied a newer version of this sticker's photo
            guard incomingGen >= (photoGenerations[sid] ?? -1) else { return }
            // Claim this generation slot before the async download so a later-arriving
            // lower-generation op (the non-cutout original) can't overwrite after we yield.
            photoGenerations[sid] = incomingGen
            Task {
                let ext = StickerAssetUploader.ext(for: urlString)
                guard let localURL = try? await StickerAssetUploader.cachedLocalURL(for: urlString, ext: ext),
                      let img = UIImage(contentsOfFile: localURL.path),
                      let i = self.stickers.firstIndex(where: { $0.id == sid }) else { return }
                // Re-check after the async download — a higher-gen op may have arrived
                guard incomingGen >= (self.photoGenerations[sid] ?? -1) else { return }
                uploadedURLs[sid] = urlString
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
                    canvasBackground = .image(img)
                }
            }
        }
    }

    private func applyRemoteAdd(_ state: StickerState) async {
        guard let result = await deserializeSticker(from: state) else { return }
        if let url = result.uploadedURL  { uploadedURLs[state.id]          = url }
        if let url = result.thumbnailURL { uploadedThumbnailURLs[state.id] = url }
        stickers.append(result.sticker)
        // Fetch music artwork (not persisted — must be re-downloaded each session)
        if case .music(let track) = result.sticker.kind, let artURL = track.artworkURL {
            let sid = state.id
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

    /// Deserializes a StickerState into a live Sticker, downloading remote assets as needed.
    /// Marked nonisolated so it can be called from task group tasks (parallel load in loadCanvas).
    private nonisolated func deserializeSticker(from state: StickerState) async -> StickerDeserialization? {
        let pos = CGPoint(x: state.x, y: state.y)
        let rot = Angle(radians: state.rotationRadians)

        switch state.type {
        case StickerTypeKey.photo:
            let img: UIImage?
            var cachedURL: String? = nil
            if let urlString = state.imageURL {
                let ext = StickerAssetUploader.ext(for: urlString)
                if let localURL = try? await StickerAssetUploader.cachedLocalURL(for: urlString, ext: ext) {
                    img = ext == "gif" ? UIImage.animatedGIF(from: localURL) : UIImage(contentsOfFile: localURL.path)
                    if img != nil { cachedURL = urlString }
                } else if let fn = state.imageFilename {
                    img = StickerStorage.loadImage(filename: fn)
                } else {
                    img = nil
                }
            } else if let fn = state.imageFilename {
                img = StickerStorage.loadImage(filename: fn)
            } else {
                // No URL and no filename — remote placeholder broadcast before upload completed
                let sticker = Sticker(id: state.id, kind: .photoLoading, position: pos,
                                      scale: state.scale, rotation: rot, zIndex: state.zIndex)
                return StickerDeserialization(sticker: sticker, uploadedURL: nil, thumbnailURL: nil)
            }
            guard let img else { return nil }
            let sticker = Sticker(id: state.id, kind: .photo(img), position: pos,
                                  scale: state.scale, rotation: rot, zIndex: state.zIndex)
            return StickerDeserialization(sticker: sticker, uploadedURL: cachedURL, thumbnailURL: nil)

        case StickerTypeKey.text:
            guard let content = TextStickerContent.deserialize(
                textString: state.textString, fontIndex: state.fontIndex, colorIndex: state.colorIndex,
                wrapWidth: state.textWrapWidth, alignment: state.textAlignment, bgStyle: state.textBGStyle
            ) else { return nil }
            let sticker = Sticker(id: state.id, kind: .text(content), position: pos,
                                  scale: state.scale, rotation: rot, zIndex: state.zIndex)
            return StickerDeserialization(sticker: sticker, uploadedURL: nil, thumbnailURL: nil)

        case StickerTypeKey.music:
            guard let mid = state.musicID, let title = state.musicTitle, let artist = state.musicArtist else { return nil }
            let track = MusicTrack(id: mid, title: title, artistName: artist,
                artworkURL: state.musicArtworkURLString.flatMap { URL(string: $0) },
                previewURL: state.musicPreviewURLString.flatMap { URL(string: $0) })
            let sticker = Sticker(id: state.id, kind: .music(track), position: pos,
                                  scale: state.scale, rotation: rot, zIndex: state.zIndex)
            return StickerDeserialization(sticker: sticker, uploadedURL: nil, thumbnailURL: nil)

        case StickerTypeKey.video:
            guard let vURL = state.videoURL, let tURL = state.videoThumbnailURL,
                  let localVideoURL = try? await StickerAssetUploader.cachedLocalURL(for: vURL, ext: "mp4"),
                  let localThumbURL = try? await StickerAssetUploader.cachedLocalURL(for: tURL, ext: "png"),
                  let thumb = UIImage(contentsOfFile: localThumbURL.path) else { return nil }
            let sticker = Sticker(id: state.id, kind: .video(videoURL: localVideoURL, thumbnail: thumb,
                                                              bgRemoved: state.bgRemoved ?? false),
                                  position: pos, scale: state.scale, rotation: rot, zIndex: state.zIndex)
            return StickerDeserialization(sticker: sticker, uploadedURL: vURL, thumbnailURL: tURL)

        default:
            return nil
        }
    }

    // MARK: - Collab: Broadcast

    func broadcastGestureEnded(stickerID: UUID) {
        guard let session = collabSession,
              let s = stickers.first(where: { $0.id == stickerID }) else { return }
        session.broadcast(session.opScale(stickerID: stickerID, scale: s.scale))
        session.broadcast(session.opRotate(stickerID: stickerID, radians: s.rotation.radians))
    }

    func broadcastPhotoReplaced(stickerID: UUID, image: UIImage) {
        // Cancel any in-flight original upload so its opUpdatePhoto doesn't overwrite bg-removal
        pendingUploadTasks[stickerID]?.cancel()
        pendingUploadTasks.removeValue(forKey: stickerID)
        let fn = "\(stickerID.uuidString).png"
        Task.detached(priority: .utility) { StickerStorage.saveImage(image, filename: fn) }
        uploadedURLs.removeValue(forKey: stickerID)
        // Bump generation so any already-broadcast generation-1 op is ignored by receivers
        let gen = (broadcastPhotoGenerations[stickerID] ?? 1) + 1
        broadcastPhotoGenerations[stickerID] = gen
        Task(priority: .utility) { [weak self] in
            let uploadID = UUID()
            guard let url = try? await StickerAssetUploader.uploadImage(image, stickerID: uploadID) else { return }
            await MainActor.run {
                self?.uploadedURLs[stickerID] = url
                self?.collabSession.map { $0.broadcast($0.opUpdatePhoto(stickerID: stickerID, imageURL: url, generation: gen)) }
            }
        }
    }

    // MARK: - Sticker Management

    func deleteSticker(id: UUID) {
        guard !isReadOnly else { return }
        pendingUploadTasks[id]?.cancel()
        pendingUploadTasks.removeValue(forKey: id)
        saveUndoState()
        withAnimation(.spring(duration: 0.2)) {
            stickers.removeAll { $0.id == id }
            if selectedStickerID == id { selectedStickerID = nil }
        }
        collabSession.map { $0.broadcast($0.opDelete(stickerID: id)) }
    }

    func addTextSticker(content: TextStickerContent) {
        guard !isReadOnly else { return }
        saveUndoState()
        topZ += 1
        let sticker = Sticker(kind: .text(content), position: visibleCenter(),
                              scale: 1.0, rotation: .zero, zIndex: topZ)
        stickers.append(sticker)
        selectedStickerID = sticker.id
        if let session = collabSession {
            var state = StickerState(id: sticker.id, type: StickerTypeKey.text,
                x: sticker.position.x, y: sticker.position.y, scale: 1.0, rotationRadians: 0, zIndex: sticker.zIndex)
            CanvasSerializer.applyText(content, to: &state)
            session.broadcast(session.opAdd(sticker: state))
        }
    }

    func updateTextSticker(id: UUID, content: TextStickerContent) {
        guard !isReadOnly, let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        saveUndoState()
        stickers[idx].kind = .text(content)
        canvasUIView?.invalidateStickerCache()
        collabSession.map { $0.broadcast($0.opUpdateText(stickerID: id, content: content)) }
    }

    func setLiveBackground(_ scene: LiveBackgroundScene) {
        guard !isReadOnly else { return }
        canvasBackground = .liveScene(scene)
    }

    func setBackgroundColor(_ color: UIColor) {
        guard !isReadOnly else { return }
        canvasBackground = .color(color)
        if let session = collabSession {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            session.broadcast(session.opUpdateBackground(colorComponents: [r, g, b, a]))
        }
    }

    func addStickerFromImage(from item: PhotosPickerItem) async {
        guard !isReadOnly else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }

        let stickerID = UUID()
        let uiImage: UIImage

        if data.isGIF, let animated = UIImage.animatedGIF(from: data) {
            uiImage = animated
            let fn = "\(stickerID.uuidString).gif"
            Task.detached(priority: .utility) { StickerStorage.saveGIF(data, filename: fn) }
        } else {
            guard let img = UIImage(data: data)?.normalized() else { return }
            uiImage = img
            let fn = "\(stickerID.uuidString).png"
            Task.detached(priority: .utility) { StickerStorage.saveImage(img, filename: fn) }
        }

        saveUndoState()
        topZ += 1
        let sticker = Sticker(id: stickerID, kind: .photo(uiImage), position: visibleCenter(),
                              scale: 1.0, rotation: .zero, zIndex: topZ)
        stickers.append(sticker)
        selectedStickerID = sticker.id

        if let session = collabSession, tapestryID != nil {
            // Broadcast opAdd immediately with no URL — remote clients get a loading placeholder
            let placeholderState = StickerState(id: stickerID, type: StickerTypeKey.photo,
                x: sticker.position.x, y: sticker.position.y, scale: 1.0, rotationRadians: 0,
                zIndex: sticker.zIndex)
            session.broadcast(session.opAdd(sticker: placeholderState))

            // Generation 1 = original photo. bg-removal will use generation 2+.
            broadcastPhotoGenerations[stickerID] = 1
            // Upload in background; broadcast opUpdatePhoto when done
            let img = uiImage
            let task = Task(priority: .utility) { [weak self] in
                let url: String?
                if img.images != nil {
                    url = try? await StickerAssetUploader.uploadGIF(stickerID: stickerID)
                } else {
                    url = try? await StickerAssetUploader.uploadImage(img, stickerID: stickerID)
                }
                guard let url, !Task.isCancelled else { return }
                await MainActor.run {
                    self?.uploadedURLs[stickerID] = url
                    self?.pendingUploadTasks.removeValue(forKey: stickerID)
                    session.broadcast(session.opUpdatePhoto(stickerID: stickerID, imageURL: url, generation: 1))
                }
            }
            pendingUploadTasks[stickerID] = task
        }
    }

    func addStickerFromCapturedImage(_ image: UIImage) {
        guard !isReadOnly else { return }
        let normalized = image.normalized()
        let stickerID = UUID()
        saveUndoState()
        topZ += 1
        let sticker = Sticker(id: stickerID, kind: .photo(normalized), position: visibleCenter(),
                              scale: 1.0, rotation: .zero, zIndex: topZ)
        stickers.append(sticker)
        selectedStickerID = sticker.id

        if let session = collabSession {
            // Broadcast opAdd immediately with no URL — remote clients get a loading placeholder
            let placeholderState = StickerState(id: stickerID, type: StickerTypeKey.photo,
                x: sticker.position.x, y: sticker.position.y, scale: 1.0, rotationRadians: 0,
                zIndex: sticker.zIndex)
            session.broadcast(session.opAdd(sticker: placeholderState))

            // Generation 1 = original photo. bg-removal will use generation 2+.
            broadcastPhotoGenerations[stickerID] = 1
            // Upload in background; broadcast opUpdatePhoto when done
            let img = normalized
            let task = Task(priority: .utility) { [weak self] in
                guard let url = try? await StickerAssetUploader.uploadImage(img, stickerID: stickerID),
                      !Task.isCancelled else { return }
                await MainActor.run {
                    self?.uploadedURLs[stickerID] = url
                    self?.pendingUploadTasks.removeValue(forKey: stickerID)
                    session.broadcast(session.opUpdatePhoto(stickerID: stickerID, imageURL: url, generation: 1))
                }
            }
            pendingUploadTasks[stickerID] = task
        }
    }

    func addVideoSticker(result: VideoProcessor.Result) {
        guard !isReadOnly else { return }
        saveUndoState()
        topZ += 1
        let sticker = Sticker(
            kind: .video(videoURL: result.outputURL, thumbnail: result.thumbnail, bgRemoved: result.bgRemoved),
            position: visibleCenter(), scale: 1.0, rotation: .zero, zIndex: topZ
        )
        stickers.append(sticker)
        selectedStickerID = sticker.id

        if let session = collabSession {
            let sid = sticker.id; let pos = sticker.position; let z = sticker.zIndex
            let srcURL = result.outputURL; let thumb = result.thumbnail; let bgRemoved = result.bgRemoved
            Task(priority: .utility) { [weak self] in
                guard let vURL = try? await StickerAssetUploader.uploadVideo(from: srcURL, stickerID: sid),
                      let tURL = try? await StickerAssetUploader.uploadVideoThumbnail(thumb, stickerID: sid) else { return }
                await MainActor.run { self?.uploadedURLs[sid] = vURL; self?.uploadedThumbnailURLs[sid] = tURL }
                var state = StickerState(id: sid, type: StickerTypeKey.video,
                    x: pos.x, y: pos.y, scale: 1.0, rotationRadians: 0, zIndex: z)
                state.videoURL = vURL; state.videoThumbnailURL = tURL; state.bgRemoved = bgRemoved
                session.broadcast(session.opAdd(sticker: state))
            }
        }
    }

    func addMusicSticker(track: MusicTrack) {
        guard !isReadOnly else { return }
        saveUndoState()
        topZ += 1
        let sticker = Sticker(kind: .music(track), position: visibleCenter(),
                              scale: 1.0, rotation: .zero, zIndex: topZ)
        stickers.append(sticker)
        selectedStickerID = sticker.id

        if let session = collabSession {
            var state = StickerState(id: sticker.id, type: StickerTypeKey.music,
                x: sticker.position.x, y: sticker.position.y, scale: 1.0, rotationRadians: 0, zIndex: sticker.zIndex)
            state.musicID = track.id; state.musicTitle = track.title; state.musicArtist = track.artistName
            state.musicArtworkURLString = track.artworkURL?.absoluteString
            state.musicPreviewURLString = track.previewURL?.absoluteString
            session.broadcast(session.opAdd(sticker: state))
        }

        Task {
            guard let artURL = track.artworkURL,
                  let (data, _) = try? await URLSession.shared.data(from: artURL),
                  let img = UIImage(data: data) else { return }
            if let idx = stickers.firstIndex(where: { $0.id == sticker.id }),
               case .music(var t) = stickers[idx].kind {
                t.artworkImage = img
                stickers[idx].kind = .music(t)
            }
        }
    }

    /// Loads a background photo from a PhotosPickerItem.
    /// Note: the caller (view) is responsible for resetting bgPickerItem and closing the sheet.
    func loadBackgroundImage(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data)?.normalized() else { return }
        canvasBackground = .image(uiImage)
        if let session = collabSession {
            let img = uiImage
            Task(priority: .utility) {
                let bgID = UUID()
                guard let url = try? await StickerAssetUploader.uploadImage(img, stickerID: bgID) else { return }
                session.broadcast(session.opUpdateBackground(imageURL: url))
            }
        }
    }

    // MARK: - Undo

    func saveUndoState() {
        undoStack.append(CanvasSnapshot(stickers: stickers, topZ: topZ))
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    func undo() {
        guard !isReadOnly else { return }
        guard let snapshot = undoStack.popLast() else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let before = stickers
        withAnimation(.spring(duration: 0.25)) {
            stickers = snapshot.stickers
            topZ     = snapshot.topZ
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        broadcastUndoDiff(before: before, after: snapshot.stickers)
    }

    private func broadcastUndoDiff(before: [Sticker], after: [Sticker]) {
        guard let session = collabSession else { return }

        let beforeIDs = Set(before.map { $0.id })
        let afterIDs  = Set(after.map  { $0.id })

        for s in before where !afterIDs.contains(s.id) {
            session.broadcast(session.opDelete(stickerID: s.id))
        }

        for s in after where !beforeIDs.contains(s.id) {
            var state = StickerState(id: s.id, type: "", x: s.position.x, y: s.position.y,
                                     scale: s.scale, rotationRadians: s.rotation.radians, zIndex: s.zIndex)
            switch s.kind {
            case .photo:
                state.type = StickerTypeKey.photo
                state.imageURL      = uploadedURLs[s.id]
                state.imageFilename = "\(s.id.uuidString).png"
                guard state.imageURL != nil else { continue }
            case .photoLoading:
                continue  // loading placeholder has no URL — skip
            case .text(let c):
                CanvasSerializer.applyText(c, to: &state)
            case .music(let t):
                CanvasSerializer.applyMusic(t, to: &state)
            case .video:
                state.type = StickerTypeKey.video
                state.videoURL = uploadedURLs[s.id]
                guard state.videoURL != nil else { continue }
            }
            session.broadcast(session.opAdd(sticker: state))
        }

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

    // MARK: - Canvas Helpers

    func bringToFront(stickerID: UUID) {
        guard !isReadOnly, let idx = stickers.firstIndex(where: { $0.id == stickerID }) else { return }
        topZ += 1
        stickers[idx].zIndex = topZ
        collabSession?.broadcast(collabSession!.opReorder(stickerID: stickerID, zIndex: topZ))
    }

    func visibleCenter() -> CGPoint {
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
