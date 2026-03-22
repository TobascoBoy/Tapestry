import SwiftUI
import UIKit

// MARK: - CanvasUIView

final class CanvasUIView: UIView {

    // MARK: Thumbnail rendering

    func renderViewportThumbnail(in captureRect: CGRect) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)

        struct VideoRenderInfo {
            let centerInCanvas: CGPoint
            let centerInSelf: CGPoint
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

    func renderViewportThumbnail(aspectRatio: CGFloat = 1.0) -> UIImage? {
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

        return image
    }

    // MARK: Subviews & state

    private weak var coordinator: CanvasCoordinator?

    let canvasView = UIView()
    private let backgroundColorView = UIView()
    private let backgroundImageView = UIImageView()
    private let centerGlowLayer = CAGradientLayer()
    private var liveSceneView: LiveBackgroundView?
    private var stickerViews:        [UUID: StickerUIView]          = [:]
    private var stickerCoordinators: [UUID: StickerCoordinator]     = [:]
    private var musicViews:          [UUID: MusicStickerUIView]     = [:]
    private var musicCoordinators:   [UUID: MusicStickerCoordinator] = [:]
    private var videoViews:          [UUID: VideoStickerUIView]     = [:]
    private var videoCoordinators:   [UUID: VideoStickerCoordinator] = [:]

    private(set) var scrollView: UIScrollView?
    let isVertical: Bool
    var isReadOnly: Bool = false

    private static let verticalCanvasHeight: CGFloat = 3000

    // MARK: Init

    init(coordinator: CanvasCoordinator, mode: CanvasMode = .infinite) {
        self.coordinator = coordinator
        self.isVertical  = mode == .vertical
        super.init(frame: .zero)
        backgroundColor = UIColor.systemBackground

        if isVertical {
            let w = UIScreen.main.bounds.width
            let h = CanvasUIView.verticalCanvasHeight
            canvasView.frame = CGRect(x: 0, y: 0, width: w, height: h)
            canvasView.backgroundColor = .clear

            let sv = UIScrollView()
            sv.showsHorizontalScrollIndicator = false
            sv.alwaysBounceVertical = true
            sv.contentSize = CGSize(width: w, height: h)
            sv.minimumZoomScale = 0.6
            sv.maximumZoomScale = 4.0
            sv.delegate = self
            addSubview(sv)
            sv.addSubview(canvasView)
            scrollView = sv
        } else {
            canvasView.frame = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
            canvasView.backgroundColor = .clear
            addSubview(canvasView)
        }

        backgroundColorView.frame = canvasView.bounds
        backgroundColorView.backgroundColor = .white
        backgroundColorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.addSubview(backgroundColorView)

        if !isVertical {
            centerGlowLayer.type       = .radial
            centerGlowLayer.colors     = [
                UIColor(red: 1.0, green: 0.91, blue: 0.76, alpha: 1.0).cgColor,
                UIColor.white.cgColor
            ]
            centerGlowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
            centerGlowLayer.endPoint   = CGPoint(x: 1.0, y: 1.0)
            centerGlowLayer.frame      = backgroundColorView.bounds
            backgroundColorView.layer.addSublayer(centerGlowLayer)
        }

        backgroundImageView.frame = canvasView.bounds
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.isHidden = true
        backgroundImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.addSubview(backgroundImageView)

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
        (scrollView ?? self).addGestureRecognizer(tap)

        coordinator.canvasView = canvasView
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

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

    // MARK: Background & transform

    func syncBackground(_ background: CanvasBackground) {
        // Tear down any existing live scene whenever we switch away from it
        if case .liveScene = background {} else {
            liveSceneView?.stopAnimating()
            liveSceneView?.removeFromSuperview()
            liveSceneView = nil
        }

        switch background {
        case .color(let color):
            backgroundColorView.backgroundColor = color
            backgroundColorView.isHidden = false
            backgroundImageView.isHidden = true
            if !isVertical { updateGlowColors(for: color) }
        case .image(let image):
            backgroundImageView.image = image
            backgroundImageView.isHidden = false
            backgroundColorView.isHidden = true
        case .liveScene(let scene):
            backgroundColorView.isHidden = true
            backgroundImageView.isHidden = true
            if liveSceneView?.scene != scene {
                liveSceneView?.stopAnimating()
                liveSceneView?.removeFromSuperview()
                let v = LiveBackgroundView(scene: scene)
                v.frame = canvasView.bounds
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                // Insert behind all sticker content but above the color/image views
                canvasView.insertSubview(v, at: 0)
                liveSceneView = v
            }
            liveSceneView?.startAnimating()
        }
    }

    /// Updates the center glow gradient so it blends naturally with any background color.
    /// The inner color is a warm-tinted lighter version of the base; the outer matches the base exactly.
    private func updateGlowColors(for baseColor: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        baseColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        // Blend 55% toward the original warm-glow tint so the center stays inviting on any color.
        let blend: CGFloat = 0.55
        let centerColor = UIColor(
            red:   min(r * (1 - blend) + 1.00 * blend, 1),
            green: min(g * (1 - blend) + 0.91 * blend, 1),
            blue:  min(b * (1 - blend) + 0.76 * blend, 1),
            alpha: a
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        centerGlowLayer.colors = [centerColor.cgColor, baseColor.cgColor]
        CATransaction.commit()
    }

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

        coordinator?.isLassoActive    = true
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
            lastSyncedStickers = nil
            coordinator?.stickers.wrappedValue[idx].kind = .photo(masked)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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

    private func buildLassoMaskedImage(image: UIImage, localPoints: [CGPoint]) -> UIImage? {
        let viewSize: CGFloat = 220
        let W = image.size.width
        let H = image.size.height
        guard W > 0, H > 0 else { return nil }

        let scale  = min(viewSize / W, viewSize / H)
        let drawnW = W * scale
        let drawnH = H * scale
        let drawRect = CGRect(x: -drawnW / 2, y: -drawnH / 2, width: drawnW, height: drawnH)

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

    // MARK: - Sticker sync

    private var lastSyncedStickers:  [Sticker]? = nil
    private var lastSyncedSelection: UUID?       = nil

    func invalidateStickerCache() { lastSyncedStickers = nil }

    func syncStickersIfNeeded(stickers: [Sticker], selectedID: UUID?) {
        let stickersSame = lastSyncedStickers.map { $0.elementsEqual(stickers, by: { a, b in
            guard a.id == b.id && a.position == b.position &&
                  a.scale == b.scale && a.rotation == b.rotation && a.zIndex == b.zIndex
            else { return false }
            switch (a.kind, b.kind) {
            case (.photo(let ia), .photo(let ib)):       return ia === ib
            case (.text(let ta),  .text(let tb)):
                return ta.text == tb.text && ta.fontIndex == tb.fontIndex &&
                       ta.colorIndex == tb.colorIndex && ta.wrapWidth == tb.wrapWidth &&
                       ta.alignment == tb.alignment && ta.bgStyle == tb.bgStyle
            case (.music(let ma), .music(let mb)):       return ma.artworkImage === mb.artworkImage
            case (.photoLoading, .photoLoading):         return true
            case (.photoLoading, _), (_, .photoLoading): return false  // loading state changed
            default:                                     return true
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

        for id in Set(stickerViews.keys).subtracting(newIDs) {
            stickerViews[id]?.removeFromSuperview()
            stickerViews[id] = nil; stickerCoordinators[id] = nil
        }
        for id in Set(musicViews.keys).subtracting(newIDs) {
            musicViews[id]?.removeFromSuperview()
            musicViews[id] = nil; musicCoordinators[id] = nil
        }
        for id in Set(videoViews.keys).subtracting(newIDs) {
            videoViews[id]?.removeFromSuperview()
            videoViews[id] = nil; videoCoordinators[id] = nil
        }

        let sorted = stickers.sorted { $0.zIndex < $1.zIndex }

        let gestureStart: () -> Void = { [weak coordinator] in
            coordinator?.onStickerGestureStart?()
            coordinator?.canvasPan?.isEnabled   = false
            coordinator?.canvasPinch?.isEnabled = false
        }
        let gestureEnd: () -> Void = { [weak coordinator] in
            guard coordinator?.isLassoActive != true else { return }
            coordinator?.canvasPan?.isEnabled   = true
            coordinator?.canvasPinch?.isEnabled = true
        }

        for sticker in sorted {
            switch sticker.kind {
            case .photo(let img):
                if stickerViews[sticker.id] == nil {
                    let binding = coordinator.bindingForSticker(id: sticker.id)
                    let sc = StickerCoordinator(sticker: binding, onTapSelect: { [weak self] in
                        self?.coordinator?.onTapSticker(sticker.id)
                    })
                    sc.isReadOnly = isReadOnly
                    let sid = sticker.id
                    sc.onGestureStart = gestureStart
                    sc.onGestureEnd = { [weak coordinator, sid] in
                        guard coordinator?.isLassoActive != true else { return }
                        coordinator?.canvasPan?.isEnabled   = true
                        coordinator?.canvasPinch?.isEnabled = true
                        coordinator?.onStickerGestureEnded?(sid)
                    }
                    sc.onDragChanged   = { [weak coordinator] p in coordinator?.onDragChanged?(p) }
                    sc.onDragEnded     = { [weak coordinator] p in coordinator?.onDragEnded?(p, sid) }
                    sc.onDoubleTap     = { [weak coordinator] in coordinator?.onDoubleTap?(sid) }
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

            case .photoLoading:
                if stickerViews[sticker.id] == nil {
                    let binding = coordinator.bindingForSticker(id: sticker.id)
                    let sc = StickerCoordinator(sticker: binding, onTapSelect: { [weak self] in
                        self?.coordinator?.onTapSticker(sticker.id)
                    })
                    sc.isReadOnly = isReadOnly
                    let sid = sticker.id
                    sc.onGestureStart = gestureStart
                    sc.onGestureEnd = { [weak coordinator, sid] in
                        guard coordinator?.isLassoActive != true else { return }
                        coordinator?.canvasPan?.isEnabled   = true
                        coordinator?.canvasPinch?.isEnabled = true
                        coordinator?.onStickerGestureEnded?(sid)
                    }
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
                sv.configureLoading(isSelected: selectedID == sticker.id)
                canvasView.bringSubviewToFront(sv)

            case .text(let content):
                if stickerViews[sticker.id] == nil {
                    let binding = coordinator.bindingForSticker(id: sticker.id)
                    let sc = StickerCoordinator(sticker: binding, onTapSelect: { [weak self] in
                        self?.coordinator?.onTapSticker(sticker.id)
                    })
                    sc.isReadOnly = isReadOnly
                    let sid = sticker.id
                    sc.onGestureStart = gestureStart
                    sc.onGestureEnd = { [weak coordinator, sid] in
                        guard coordinator?.isLassoActive != true else { return }
                        coordinator?.canvasPan?.isEnabled   = true
                        coordinator?.canvasPinch?.isEnabled = true
                        coordinator?.onStickerGestureEnded?(sid)
                    }
                    sc.onDragChanged = { [weak coordinator] p in coordinator?.onDragChanged?(p) }
                    sc.onDragEnded   = { [weak coordinator] p in coordinator?.onDragEnded?(p, sid) }
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
                    let mc = MusicStickerCoordinator(stickerID: sid, previewURL: track.previewURL)
                    mc.isReadOnly     = isReadOnly
                    mc.onTapSelect    = { [weak self] in self?.coordinator?.onTapSticker(sid) }
                    mc.onGestureStart = gestureStart
                    mc.onGestureEnd   = { [weak coordinator, sid] in
                        guard coordinator?.isLassoActive != true else { return }
                        coordinator?.canvasPan?.isEnabled   = true
                        coordinator?.canvasPinch?.isEnabled = true
                        coordinator?.onStickerGestureEnded?(sid)
                    }
                    mc.onPositionChanged = { [weak self] newPos in
                        guard let self,
                              let idx = self.coordinator?.stickers.wrappedValue.firstIndex(where: { $0.id == sid })
                        else { return }
                        self.coordinator?.stickers.wrappedValue[idx].position = newPos
                    }
                    mc.onDragChanged  = { [weak coordinator] p in coordinator?.onDragChanged?(p) }
                    mc.onDragEnded    = { [weak coordinator] p in coordinator?.onDragEnded?(p, sid) }
                    mc.currentScale   = { [weak self] in
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
                    vc.isReadOnly     = isReadOnly
                    vc.onTapSelect    = { [weak self] in self?.coordinator?.onTapSticker(sid) }
                    vc.onDoubleTap    = { [weak coordinator] in coordinator?.onDoubleTap?(sid) }
                    vc.onGestureStart = gestureStart
                    vc.onGestureEnd   = { [weak coordinator, sid] in
                        guard coordinator?.isLassoActive != true else { return }
                        coordinator?.canvasPan?.isEnabled   = true
                        coordinator?.canvasPinch?.isEnabled = true
                        coordinator?.onStickerGestureEnded?(sid)
                    }
                    vc.onPositionChanged = { [weak self] newPos in
                        guard let self,
                              let idx = self.coordinator?.stickers.wrappedValue.firstIndex(where: { $0.id == sid })
                        else { return }
                        self.coordinator?.stickers.wrappedValue[idx].position = newPos
                    }
                    vc.onDragChanged   = { [weak coordinator] p in coordinator?.onDragChanged?(p) }
                    vc.onDragEnded     = { [weak coordinator] p in coordinator?.onDragEnded?(p, sid) }
                    vc.currentScale    = { [weak self] in
                        self?.coordinator?.stickers.wrappedValue.first(where: { $0.id == sid })?.scale ?? 1.0
                    }
                    vc.currentRotation = { [weak self] in
                        self?.coordinator?.stickers.wrappedValue.first(where: { $0.id == sid })?.rotation.radians ?? 0.0
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
                vv.center = sticker.position
                vv.transform = CGAffineTransform(rotationAngle: sticker.rotation.radians)
                    .scaledBy(x: sticker.scale, y: sticker.scale)
                vv.configure(videoURL: videoURL, thumbnail: thumbnail,
                             isSelected: selectedID == sticker.id, bgRemoved: bgRemoved)
                canvasView.bringSubviewToFront(vv)
            }
        }

        // Fade the center glow out gradually starting after 3 visual stickers.
        // Fully gone by 6 stickers; fully visible at 3 or fewer.
        if !isVertical {
            let visualCount = stickers.filter {
                switch $0.kind {
                case .photo, .photoLoading, .video, .music: return true
                case .text: return false
                }
            }.count
            let fadeStart = 3, fadeEnd = 6
            let targetOpacity: Float = visualCount <= fadeStart ? 1 :
                visualCount >= fadeEnd ? 0 :
                Float(1 - Double(visualCount - fadeStart) / Double(fadeEnd - fadeStart))
            if abs(centerGlowLayer.opacity - targetOpacity) > 0.01 {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.4)
                centerGlowLayer.opacity = targetOpacity
                CATransaction.commit()
            }
        }
    }
}

// MARK: - CanvasUIView + UIScrollViewDelegate

extension CanvasUIView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvasView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let horizontalInset = max((scrollView.bounds.width  - scrollView.contentSize.width)  / 2, 0)
        let verticalInset   = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset, left: horizontalInset,
            bottom: verticalInset, right: horizontalInset
        )
    }
}

