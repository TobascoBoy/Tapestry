import UIKit
import AVFoundation

// MARK: - VideoStickerUIView

final class VideoStickerUIView: UIView {
    static let size: CGFloat = 220

    // For raw video: regular AVPlayerLayer inside a clipping container
    private let container     = UIView()
    private let thumbnailView = UIImageView()
    private var playerLayer:  AVPlayerLayer?

    // For bg-removed video: a second AVPlayerLayer with backgroundColor = nil
    private var alphaPlayerLayer: AVPlayerLayer?

    private var player:       AVPlayer?
    private var playerLooper: AVPlayerLooper?
    private var isBgRemoved   = false

    // Pixel-perfect hit testing for bg-removed video
    private var videoOutput:       AVPlayerItemVideoOutput?
    private var hitTestImage:      CGImage?
    private var maskRefreshTimer:  Timer?
    private var loopObserver:      NSObjectProtocol?
    private let ciContext          = CIContext(options: [.useSoftwareRenderer: false])

    // Overlays
    private let border        = UIView()

    weak var coordinator: VideoStickerCoordinator?

    // MARK: - Init
    // NOTE: We use a standard origin-zero coordinate system here.
    // The centering offset is applied by the canvas when positioning.

    init(coordinator: VideoStickerCoordinator) {
        self.coordinator = coordinator
        let s = VideoStickerUIView.size
        super.init(frame: CGRect(x: 0, y: 0, width: s, height: s))
        isOpaque        = false
        backgroundColor = .clear
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { cleanup() }

    // MARK: - Setup

    private func setup() {
        let s = VideoStickerUIView.size
        let r: CGFloat = 18
        let f = CGRect(x: 0, y: 0, width: s, height: s)

        // Container — used only for raw video (clips to rounded rect)
        container.frame               = f
        container.layer.cornerRadius  = r
        container.layer.cornerCurve   = .continuous
        container.clipsToBounds       = true
        container.backgroundColor     = .clear
        container.isOpaque            = false
        addSubview(container)

        thumbnailView.frame           = container.bounds
        thumbnailView.contentMode     = .scaleAspectFill
        thumbnailView.backgroundColor = .clear
        container.addSubview(thumbnailView)

        // Selection border
        border.frame                   = f
        border.layer.cornerRadius      = r
        border.layer.cornerCurve       = .continuous
        border.layer.borderColor       = UIColor.white.withAlphaComponent(0.9).cgColor
        border.layer.borderWidth       = 2.5
        border.isHidden                = true
        border.backgroundColor         = .clear
        border.isUserInteractionEnabled = false
        addSubview(border)

        // Gestures
        guard let coord = coordinator else { return }
        let tap       = UITapGestureRecognizer(target: coord, action: #selector(VideoStickerCoordinator.handleTap))
        let doubleTap = UITapGestureRecognizer(target: coord, action: #selector(VideoStickerCoordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        let pan    = UIPanGestureRecognizer(target: coord, action: #selector(VideoStickerCoordinator.handlePan))
        let pinch  = UIPinchGestureRecognizer(target: coord, action: #selector(VideoStickerCoordinator.handlePinch))
        let rotate = UIRotationGestureRecognizer(target: coord, action: #selector(VideoStickerCoordinator.handleRotate))
        [pan, pinch, rotate].forEach { $0.delegate = coord }
        coord.panGesture = pan
        [tap, doubleTap, pan, pinch, rotate].forEach { addGestureRecognizer($0) }
    }

    // MARK: - Configure

    func configure(videoURL: URL, thumbnail: UIImage, isSelected: Bool, bgRemoved: Bool) {
        isBgRemoved = bgRemoved
        let firstBuild = player == nil
        if firstBuild { buildPlayer(url: videoURL, bgRemoved: bgRemoved) }

        border.isHidden = !isSelected
        coordinator?.panGesture?.isEnabled = isSelected

        if bgRemoved {
            container.isHidden  = true
            layer.shadowOpacity = 0
        } else {
            container.isHidden  = false
            // Hide the static thumbnail immediately — the looping player takes over
            thumbnailView.image  = thumbnail
            thumbnailView.alpha  = 0
            playerLayer?.opacity = 1
            layer.shadowColor    = UIColor.black.cgColor
            layer.shadowOpacity  = 0.3
            layer.shadowRadius   = 10
            layer.shadowOffset   = CGSize(width: 0, height: 3)
        }

        // Start looping playback — no-op if already playing
        if player?.rate == 0 { player?.play() }
    }

    // MARK: - Player construction

    private func buildPlayer(url: URL, bgRemoved: Bool) {
        bgRemoved ? buildAlphaPlayer(url: url) : buildRegularPlayer(url: url)
    }

    private func buildRegularPlayer(url: URL) {
        let item   = AVPlayerItem(url: url)
        let qp     = AVQueuePlayer()
        qp.isMuted = true
        let looper = AVPlayerLooper(player: qp, templateItem: item)
        let pl     = AVPlayerLayer()
        pl.player  = qp
        pl.videoGravity = .resizeAspectFill
        pl.frame   = container.bounds
        pl.opacity = 0
        container.layer.insertSublayer(pl, above: thumbnailView.layer)
        playerLayer  = pl
        player       = qp
        playerLooper = looper
    }

    private func buildAlphaPlayer(url: URL) {
        // Apple's recommended approach for HEVC+Alpha: plain AVPlayerLayer with
        // backgroundColor = nil. The layer composites the video's alpha channel
        // directly — no manual frame pumping required.

        // IMPORTANT: use plain AVPlayer (not AVQueuePlayer + AVPlayerLooper).
        // AVPlayerLooper creates *copies* of the template AVPlayerItem — our
        // AVPlayerItemVideoOutput would be attached to the template only, meaning
        // copyPixelBuffer() returns nil for every frame after the first loop.
        // With plain AVPlayer we keep one item forever and seek to zero on end.
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(outputSettings: outputSettings)
        videoOutput = output

        let item = AVPlayerItem(url: url)
        item.add(output)

        let ap     = AVPlayer(playerItem: item)
        ap.isMuted = true

        // Loop by seeking back to zero when playback reaches the end
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak ap] _ in
            ap?.seek(to: .zero, completionHandler: { _ in ap?.play() })
        }

        let pl = AVPlayerLayer()
        pl.player          = ap
        pl.videoGravity    = .resizeAspectFill
        pl.frame           = bounds
        pl.backgroundColor = nil   // essential — lets alpha channel through
        layer.insertSublayer(pl, at: 0)
        alphaPlayerLayer = pl
        player       = ap
        playerLooper = nil   // not used for bg-removed

        // Capture the first hit-test mask once the player has its initial frame,
        // then refresh every 0.5 s so the mask tracks a moving subject.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshHitTestMask()
            self?.maskRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refreshHitTestMask()
            }
        }
    }

    private func refreshHitTestMask() {
        guard let output = videoOutput,
              let time   = player?.currentTime() else { return }
        var displayTime  = CMTime.zero
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time,
                                                        itemTimeForDisplay: &displayTime) else { return }
        // CIContext.createCGImage copies the pixel data so the CGImage is safe
        // to use after the pixel buffer is released.
        let ciImage  = CIImage(cvPixelBuffer: pixelBuffer)
        hitTestImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    // MARK: - Helpers

    private func cleanup() {
        maskRefreshTimer?.invalidate()
        maskRefreshTimer = nil
        if let obs = loopObserver {
            NotificationCenter.default.removeObserver(obs)
            loopObserver = nil
        }
        playerLooper = nil
        player?.pause()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isBgRemoved else { return bounds.contains(point) }
        guard bounds.contains(point) else { return false }

        // No mask yet — be permissive until the first frame is captured
        guard let cgImage = hitTestImage else { return true }

        let imgW = cgImage.width
        let imgH = cgImage.height

        // Map view point → image pixel, accounting for resizeAspectFill crop
        let videoAspect = CGFloat(imgW) / CGFloat(imgH)
        let viewAspect  = bounds.width  / bounds.height
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        if videoAspect > viewAspect {
            // Video wider than view — cropped on left/right
            scale   = bounds.height / CGFloat(imgH)
            offsetX = (bounds.width - CGFloat(imgW) * scale) / 2
            offsetY = 0
        } else {
            // Video taller than view — cropped on top/bottom
            scale   = bounds.width / CGFloat(imgW)
            offsetX = 0
            offsetY = (bounds.height - CGFloat(imgH) * scale) / 2
        }

        let px = Int((point.x - offsetX) / scale)
        let py = Int((point.y - offsetY) / scale)
        guard px >= 0, px < imgW, py >= 0, py < imgH else { return false }

        // 1×1 CGContext trick — draw the full image offset so the target pixel
        // lands at (0,0), then read the alpha byte. Same approach as StickerUIView.
        guard let ctx = CGContext(data: nil, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }
        ctx.draw(cgImage, in: CGRect(x: -px, y: -(imgH - py - 1),
                                     width: imgW, height: imgH))
        guard let data = ctx.data else { return true }
        let alpha = data.load(fromByteOffset: 3, as: UInt8.self)
        return alpha > 10
    }

    /// Captures the current video frame as a UIImage for use in cover photo rendering.
    /// AVPlayerLayer is GPU-rendered and skipped by layer.render(in:), so we need this
    /// to manually composite video content into cover snapshots.
    func currentFrameImage() -> UIImage? {
        guard let asset = player?.currentItem?.asset,
              let time = player?.currentTime() else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - VideoStickerCoordinator

final class VideoStickerCoordinator: NSObject, UIGestureRecognizerDelegate {
    let stickerID:         UUID
    var isReadOnly:        Bool = false
    var onTapSelect:       (() -> Void)?
    var onDoubleTap:       (() -> Void)?
    var onGestureStart:    (() -> Void)?
    var onGestureEnd:      (() -> Void)?
    var onDragChanged:     ((CGPoint) -> Void)?
    var onDragEnded:       ((CGPoint) -> Void)?
    var onPositionChanged: ((CGPoint) -> Void)?
    var onScaleChanged:    ((CGFloat) -> Void)?
    var onRotationChanged: ((Double)  -> Void)?
    var currentScale:      (() -> CGFloat)?
    var currentRotation:   (() -> Double)?
    weak var panGesture:   UIPanGestureRecognizer?

    private var panStart         = CGPoint.zero
    private var pinchStartScale: CGFloat = 1.0
    private var rotateStartAngle: Double = 0.0

    init(stickerID: UUID) { self.stickerID = stickerID }

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Only allow simultaneous recognition with gestures on the same view.
        // Returning true unconditionally lets the canvas pan fire at the same time,
        // causing the background to move while dragging the sticker.
        return gr.view === other.view
    }

    @objc func handleTap(_ gr: UITapGestureRecognizer) { onTapSelect?() }

    @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) { onDoubleTap?() }

    @objc func handlePan(_ gr: UIPanGestureRecognizer) {
        guard !isReadOnly, let v = gr.view else { return }
        switch gr.state {
        case .began:
            onGestureStart?()
            panStart = v.center
            gr.setTranslation(.zero, in: v.superview)
        case .changed:
            let t = gr.translation(in: v.superview)
            let c = CGPoint(x: panStart.x + t.x, y: panStart.y + t.y)
            v.center = c
            onPositionChanged?(c)
            onDragChanged?(v.convert(.zero, to: nil))
        case .ended, .cancelled, .failed:
            onDragEnded?(v.convert(.zero, to: nil))
            onGestureEnd?()
        default: break
        }
    }

    @objc func handlePinch(_ gr: UIPinchGestureRecognizer) {
        guard !isReadOnly else { return }
        switch gr.state {
        case .began:
            onGestureStart?()
            pinchStartScale = currentScale?() ?? 1.0
            gr.scale = 1.0
        case .changed:
            onScaleChanged?(max(0.2, min(5.0, pinchStartScale * gr.scale)))
        case .ended, .cancelled, .failed:
            onGestureEnd?()
        default: break
        }
    }

    @objc func handleRotate(_ gr: UIRotationGestureRecognizer) {
        guard !isReadOnly else { return }
        switch gr.state {
        case .began:
            onGestureStart?()
            rotateStartAngle = currentRotation?() ?? 0.0
            gr.rotation = 0
        case .changed:
            onRotationChanged?(rotateStartAngle + gr.rotation)
        case .ended, .cancelled, .failed:
            onGestureEnd?()
        default: break
        }
    }
}
