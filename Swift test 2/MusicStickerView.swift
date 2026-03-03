import UIKit
import Combine

// MARK: - MusicStickerUIView
//
// Artwork fills the entire card. A gradient scrim at the bottom makes
// text readable. The outer view carries the drop shadow (no clipping),
// and an inner container clips everything to the rounded corners.

final class MusicStickerUIView: UIView {

    static let cardWidth:  CGFloat = 200
    static let cardHeight: CGFloat = 200

    // Subviews
    private let container    = UIView()       // clips to rounded rect
    private let artworkView  = UIImageView()
    private let scrimView    = GradientView()
    private let titleLabel   = UILabel()
    private let artistLabel  = UILabel()
    private let playPauseBtn = UIButton(type: .system)
    private let progressBar  = UIView()
    private let progressFill = UIView()
    private let border       = UIView()       // selection ring, outside container

    private weak var coordinator: MusicStickerCoordinator?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(coordinator: MusicStickerCoordinator) {
        self.coordinator = coordinator
        let w = MusicStickerUIView.cardWidth
        let h = MusicStickerUIView.cardHeight
        super.init(frame: CGRect(x: 0, y: 0, width: w, height: h))
        bounds = CGRect(x: -w/2, y: -h/2, width: w, height: h)
        setup()
        subscribeToPlayer()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setup() {
        let w = MusicStickerUIView.cardWidth
        let h = MusicStickerUIView.cardHeight
        let r: CGFloat = 16

        // Outer view: transparent, carries shadow only
        backgroundColor = .clear
        layer.shadowColor   = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius  = 10
        layer.shadowOffset  = CGSize(width: 0, height: 3)
        layer.shadowPath    = UIBezierPath(roundedRect: CGRect(x: -w/2, y: -h/2, width: w, height: h),
                                           cornerRadius: r).cgPath

        // Inner container: clips children to rounded corners
        container.frame = CGRect(x: -w/2, y: -h/2, width: w, height: h)
        container.layer.cornerRadius = r
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        addSubview(container)

        // Artwork fills the container
        artworkView.frame = container.bounds
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.backgroundColor = UIColor(white: 0.2, alpha: 1)
        let noteIcon = UIImageView(image: UIImage(systemName: "music.note"))
        noteIcon.tintColor = UIColor(white: 0.55, alpha: 1)
        noteIcon.contentMode = .scaleAspectFit
        noteIcon.frame = CGRect(x: w/2 - 26, y: h/2 - 52, width: 44, height: 44)
        artworkView.addSubview(noteIcon)
        container.addSubview(artworkView)

        // Gradient scrim — transparent top, dark bottom third
        scrimView.frame = container.bounds
        scrimView.isUserInteractionEnabled = false
        container.addSubview(scrimView)

        // Labels sit over the scrim
        let pad: CGFloat = 10
        let labelW = w - pad*2 - 36   // leave room for play button

        titleLabel.frame = CGRect(x: pad, y: h - 52, width: labelW, height: 18)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(titleLabel)

        artistLabel.frame = CGRect(x: pad, y: h - 32, width: labelW, height: 14)
        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = UIColor(white: 0.85, alpha: 1)
        artistLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(artistLabel)

        // Play/pause — bottom right
        let btnSize: CGFloat = 30
        playPauseBtn.frame = CGRect(x: w - btnSize - pad, y: h - btnSize - pad, width: btnSize, height: btnSize)
        playPauseBtn.tintColor = .white
        playPauseBtn.setImage(
            UIImage(systemName: "play.circle.fill",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)),
            for: .normal)
        playPauseBtn.addTarget(coordinator,
                               action: #selector(MusicStickerCoordinator.playPauseTapped),
                               for: .touchUpInside)
        container.addSubview(playPauseBtn)

        // Progress bar — very bottom edge, full width
        let barH: CGFloat = 3
        progressBar.frame = CGRect(x: 0, y: h - barH, width: w, height: barH)
        progressBar.backgroundColor = UIColor(white: 1, alpha: 0.3)
        container.addSubview(progressBar)

        progressFill.frame = CGRect(x: 0, y: h - barH, width: 0, height: barH)
        progressFill.backgroundColor = .white
        container.addSubview(progressFill)

        // Selection border — sits outside container so it's not clipped
        border.frame = CGRect(x: -w/2, y: -h/2, width: w, height: h)
        border.layer.cornerRadius = r
        border.layer.cornerCurve = .continuous
        border.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        border.layer.borderWidth = 2.5
        border.isHidden = true
        border.isUserInteractionEnabled = false
        addSubview(border)

        // Gestures
        guard let coord = coordinator else { return }
        let tap    = UITapGestureRecognizer(target: coord, action: #selector(MusicStickerCoordinator.handleTap))
        let pan    = UIPanGestureRecognizer(target: coord, action: #selector(MusicStickerCoordinator.handlePan))
        let pinch  = UIPinchGestureRecognizer(target: coord, action: #selector(MusicStickerCoordinator.handlePinch))
        let rotate = UIRotationGestureRecognizer(target: coord, action: #selector(MusicStickerCoordinator.handleRotate))
        [pan, pinch, rotate].forEach { $0.delegate = coord }
        coord.panGesture = pan
        for g in [tap, pan, pinch, rotate] { addGestureRecognizer(g) }
    }

    // MARK: - Player subscription

    private func subscribeToPlayer() {
        guard let coord = coordinator else { return }
        let myID = coord.stickerID

        MusicPlayerManager.shared.$currentlyPlayingID
            .combineLatest(MusicPlayerManager.shared.$isPlaying)
            .receive(on: RunLoop.main)
            .sink { [weak self] (playingID, playing) in
                let isMine = playingID == myID && playing
                let name = isMine ? "pause.circle.fill" : "play.circle.fill"
                self?.playPauseBtn.setImage(
                    UIImage(systemName: name,
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)),
                    for: .normal)
            }
            .store(in: &cancellables)

        MusicPlayerManager.shared.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] prog in
                guard MusicPlayerManager.shared.currentlyPlayingID == myID else { return }
                guard let bar = self?.progressBar else { return }
                UIView.animate(withDuration: 0.1) {
                    self?.progressFill.frame = CGRect(
                        x: bar.frame.minX, y: bar.frame.minY,
                        width: bar.frame.width * CGFloat(prog),
                        height: bar.frame.height)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Configure

    func configure(track: MusicTrack, isSelected: Bool) {
        titleLabel.text  = track.title
        artistLabel.text = track.artistName
        if let art = track.artworkImage {
            artworkView.subviews.forEach { $0.isHidden = true }
            artworkView.image = art
        }
        border.isHidden = !isSelected
        layer.shadowRadius = isSelected ? 14 : 10
        coordinator?.panGesture?.isEnabled = isSelected
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }
}

// MARK: - MusicStickerCoordinator

final class MusicStickerCoordinator: NSObject, UIGestureRecognizerDelegate {
    let stickerID: UUID
    var onPositionChanged: ((CGPoint) -> Void)?
    var onTapSelect: (() -> Void)?
    var onGestureStart: (() -> Void)?
    var onGestureEnd: (() -> Void)?
    var onDragChanged:     ((CGPoint) -> Void)?
    var onDragEnded:       ((CGPoint) -> Void)?
    var onScaleChanged:    ((CGFloat) -> Void)?
    var onRotationChanged: ((Double)  -> Void)?
    var currentScale:      (() -> CGFloat)?
    var currentRotation:   (() -> Double)?
    weak var panGesture:   UIPanGestureRecognizer?

    private var previewURL:        URL?
    private var panStartPosition:  CGPoint = .zero
    private var pinchStartScale:   CGFloat = 1.0
    private var rotateStartAngle:  Double  = 0.0

    init(stickerID: UUID, previewURL: URL?) {
        self.stickerID  = stickerID
        self.previewURL = previewURL
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc func handleTap(_ gr: UITapGestureRecognizer) { onTapSelect?() }

    @objc func playPauseTapped() {
        guard let url = previewURL else { return }
        Task { @MainActor in
            let mgr = MusicPlayerManager.shared
            if mgr.currentlyPlayingID == stickerID && mgr.isPlaying {
                mgr.pause()
            } else {
                mgr.play(stickerID: stickerID, url: url)
            }
        }
    }

    @objc func handlePan(_ gr: UIPanGestureRecognizer) {
        guard let view = gr.view else { return }
        switch gr.state {
        case .began:
            onGestureStart?()
            panStartPosition = view.center
            gr.setTranslation(.zero, in: view.superview)
        case .changed:
            let t = gr.translation(in: view.superview)
            let newCenter = CGPoint(x: panStartPosition.x + t.x, y: panStartPosition.y + t.y)
            view.center = newCenter
            onPositionChanged?(newCenter)
            onDragChanged?(view.convert(.zero, to: nil))
        case .ended, .cancelled, .failed:
            onDragEnded?(view.convert(.zero, to: nil))
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

// MARK: - GradientView

private final class GradientView: UIView {
    private let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradientLayer.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.7).cgColor,
        ]
        gradientLayer.locations = [0, 0.45, 1]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint   = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradientLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }
}
