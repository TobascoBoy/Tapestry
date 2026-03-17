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
        let item   = AVPlayerItem(url: url)
        let qp     = AVQueuePlayer()
        qp.isMuted = true
        let looper = AVPlayerLooper(player: qp, templateItem: item)
        let pl     = AVPlayerLayer()
        pl.player          = qp
        pl.videoGravity    = .resizeAspectFill
        pl.frame           = bounds
        pl.backgroundColor = nil   // essential — lets alpha channel through
        layer.insertSublayer(pl, at: 0)
        alphaPlayerLayer = pl
        player       = qp
        playerLooper = looper
    }

    // MARK: - Helpers

    private func cleanup() {
        playerLooper = nil
        player?.pause()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
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
        guard let v = gr.view else { return }
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
