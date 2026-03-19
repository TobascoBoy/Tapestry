import UIKit

// MARK: - LassoOverlayView
//
// Full-canvas overlay that captures a freehand lasso stroke.
// Sits on top of CanvasUIView (not inside canvasView) so it stays fixed
// regardless of canvas pan/zoom. Points are reported in the overlay's own
// coordinate space; callers convert to sticker-local space via
// stickerView.convert(_:from: self).

final class LassoOverlayView: UIView {

    /// Called when the user lifts their finger with ≥ 3 points drawn.
    var onComplete: (([CGPoint]) -> Void)?
    /// Called when the user taps Cancel or draws too few points.
    var onCancel:   (() -> Void)?

    // MARK: - Layers / subviews

    private let shadowLayer = CAShapeLayer()   // dark drop-shadow stroke
    private let fillLayer   = CAShapeLayer()   // translucent interior fill
    private let strokeLayer = CAShapeLayer()   // white marching-ants stroke

    private let hintLabel    = UILabel()
    private let cancelButton = UIButton(type: .system)

    // MARK: - State

    private var points: [CGPoint] = []

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.35)
        isUserInteractionEnabled = true
        setupLayers()
        setupControls()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layer setup

    private func setupLayers() {
        // 1. Drop shadow
        shadowLayer.fillColor   = UIColor.clear.cgColor
        shadowLayer.strokeColor = UIColor.black.withAlphaComponent(0.45).cgColor
        shadowLayer.lineWidth   = 3.5
        shadowLayer.lineCap     = .round
        shadowLayer.lineJoin    = .round
        layer.addSublayer(shadowLayer)

        // 2. Fill
        fillLayer.fillColor   = UIColor.white.withAlphaComponent(0.14).cgColor
        fillLayer.strokeColor = UIColor.clear.cgColor
        layer.addSublayer(fillLayer)

        // 3. White dashed stroke (marching ants)
        strokeLayer.fillColor   = UIColor.clear.cgColor
        strokeLayer.strokeColor = UIColor.white.cgColor
        strokeLayer.lineWidth   = 2.0
        strokeLayer.lineDashPattern = [8, 5]
        strokeLayer.lineCap     = .round
        strokeLayer.lineJoin    = .round
        layer.addSublayer(strokeLayer)

        // Animate the dashes
        let anim = CABasicAnimation(keyPath: "lineDashPhase")
        anim.fromValue  = 0
        anim.toValue    = 26        // 8 + 5 = 13 × 2 for a smooth cycle
        anim.duration   = 0.7
        anim.repeatCount = .infinity
        strokeLayer.add(anim, forKey: "marchingAnts")
    }

    private func setupControls() {
        // Instruction label
        hintLabel.text          = "Draw to cut out"
        hintLabel.textColor     = .white
        hintLabel.font          = .systemFont(ofSize: 16, weight: .semibold)
        hintLabel.textAlignment = .center
        hintLabel.layer.shadowColor   = UIColor.black.cgColor
        hintLabel.layer.shadowOpacity = 0.7
        hintLabel.layer.shadowRadius  = 4
        hintLabel.layer.shadowOffset  = .zero
        addSubview(hintLabel)

        // Cancel pill button
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        cancelButton.tintColor        = .white
        cancelButton.backgroundColor  = UIColor.black.withAlphaComponent(0.45)
        cancelButton.layer.cornerRadius      = 20
        cancelButton.layer.cornerCurve       = .continuous
        cancelButton.layer.borderColor       = UIColor.white.withAlphaComponent(0.3).cgColor
        cancelButton.layer.borderWidth       = 1
        cancelButton.contentEdgeInsets       = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        addSubview(cancelButton)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hintLabel.frame = CGRect(x: 0, y: 88, width: bounds.width, height: 26)
        cancelButton.sizeToFit()
        let bw = cancelButton.bounds.width + 40
        let bh: CGFloat = 44
        cancelButton.frame = CGRect(
            x: (bounds.width - bw) / 2,
            y: bounds.height - 80,
            width: bw, height: bh
        )
        cancelButton.layer.cornerRadius = bh / 2
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        points = [touch.location(in: self)]
        UIView.animate(withDuration: 0.15) { self.hintLabel.alpha = 0 }
        updatePath(closed: false)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = touch.location(in: self)
        // Subsample: skip points that are very close together
        if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 5 { return }
        points.append(p)
        updatePath(closed: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard points.count >= 3 else { onCancel?(); return }
        updatePath(closed: true)
        // Hold the closed path briefly so the user sees it close before it's applied
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.onComplete?(self.points)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onCancel?()
    }

    // MARK: - Path rendering

    private func updatePath(closed: Bool) {
        guard !points.isEmpty else { return }
        let path = UIBezierPath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        if closed { path.close() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cgPath = path.cgPath
        shadowLayer.path = cgPath
        fillLayer.path   = cgPath
        strokeLayer.path = cgPath
        CATransaction.commit()
    }

    // MARK: - Cancel

    @objc private func cancelTapped() { onCancel?() }

    // Route cancel-button taps through even though we intercept everything else
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        cancelButton.frame.contains(point) ? cancelButton : self
    }
}
