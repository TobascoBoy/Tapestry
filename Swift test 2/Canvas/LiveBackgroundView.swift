import UIKit
import QuartzCore

// MARK: - LiveBackgroundView

/// A UIView that renders a looping animated background.
/// Night sky: procedural CoreAnimation stars + sparkles.
/// Moving clouds: real photographic sky image fetched from Unsplash, scrolled as a seamless tile.
final class LiveBackgroundView: UIView {

    // MARK: - State

    private(set) var scene: LiveBackgroundScene
    private var isAnimating = false

    // Night sky
    private var starEmitter: CAEmitterLayer?

    // Moving clouds – photo-based seamless scroll
    private var cloudImageViews: [UIImageView] = []
    private var cloudScrollWidth: CGFloat = 0
    private var cloudDisplayLink: CADisplayLink?
    private var lastCloudTick: CFTimeInterval = 0
    private static let cloudScrollSpeed: CGFloat = 22  // points per second

    // Unsplash direct URL for a wide blue-sky-with-clouds photo.
    // w=1600 gives 2× retina quality on all current iPhones.
    private static let cloudPhotoURL = URL(string:
        "https://images.unsplash.com/photo-1501630834273-4b5604d2ee31?w=1600&q=85&auto=format&fit=crop")!

    // MARK: - Init

    init(scene: LiveBackgroundScene) {
        self.scene = scene
        super.init(frame: .zero)
        clipsToBounds = true
        buildScene()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        cloudDisplayLink?.invalidate()
    }

    // MARK: - Layout

    private var builtSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, builtSize != bounds.size else { return }
        builtSize = bounds.size
        teardownScene()
        buildScene()
        if isAnimating { startAnimating() }
    }

    // MARK: - Public API

    func startAnimating() {
        isAnimating = true
        switch scene {
        case .nightSky:
            starEmitter?.birthRate = 1
        case .movingClouds:
            if !cloudImageViews.isEmpty { startCloudDisplayLink() }
        }
    }

    func stopAnimating() {
        isAnimating = false
        starEmitter?.birthRate = 0
        cloudDisplayLink?.invalidate()
        cloudDisplayLink = nil
    }

    // MARK: - Scene teardown

    private func teardownScene() {
        stopAnimating()
        subviews.forEach { $0.removeFromSuperview() }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        starEmitter = nil
        cloudImageViews = []
        cloudScrollWidth = 0
    }

    // MARK: - Scene construction

    private func buildScene() {
        switch scene {
        case .nightSky:    buildNightSky()
        case .movingClouds: buildMovingClouds()
        }
    }

    // MARK: - Night Sky

    private func buildNightSky() {
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.type = .radial
        gradient.startPoint = CGPoint(x: 0.5, y: 0.4)
        gradient.endPoint   = CGPoint(x: 1.0, y: 1.0)
        gradient.colors = [
            UIColor(red: 0.06, green: 0.07, blue: 0.18, alpha: 1).cgColor,
            UIColor(red: 0.02, green: 0.02, blue: 0.07, alpha: 1).cgColor,
        ]
        layer.addSublayer(gradient)

        let moonGlow = CAGradientLayer()
        moonGlow.frame = bounds
        moonGlow.type = .radial
        moonGlow.startPoint = CGPoint(x: 0.78, y: 0.12)
        moonGlow.endPoint   = CGPoint(x: 1.0,  y: 0.55)
        moonGlow.colors = [
            UIColor(red: 0.55, green: 0.65, blue: 0.90, alpha: 0.18).cgColor,
            UIColor.clear.cgColor,
        ]
        layer.addSublayer(moonGlow)

        addStaticStars()

        let emitter = CAEmitterLayer()
        emitter.frame           = bounds
        emitter.renderMode      = .additive
        emitter.emitterShape    = .rectangle
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        emitter.emitterSize     = bounds.size

        let star = CAEmitterCell()
        star.contents      = starImage().cgImage
        star.birthRate     = 0
        star.lifetime      = 5.0
        star.lifetimeRange = 4.0
        star.velocity      = 0
        star.scale         = 0.04
        star.scaleRange    = 0.06
        star.alphaRange    = 1.0
        star.color         = UIColor(white: 1, alpha: 0.85).cgColor
        star.duration      = 4

        var tinted = star
        tinted.color      = UIColor(red: 0.80, green: 0.90, blue: 1.0, alpha: 0.60).cgColor
        tinted.scale      = 0.025
        tinted.scaleRange = 0.03

        emitter.emitterCells = [star, tinted]
        layer.addSublayer(emitter)
        starEmitter = emitter
    }

    private func addStaticStars() {
        var rng = SystemRandomNumberGenerator()
        let starLayer = CALayer()
        starLayer.frame = bounds

        for _ in 0..<130 {
            let size = CGFloat.random(in: 0.8...2.6, using: &rng)
            let dot = CALayer()
            dot.frame = CGRect(
                x: CGFloat.random(in: 0...bounds.width,  using: &rng),
                y: CGFloat.random(in: 0...bounds.height, using: &rng),
                width: size, height: size
            )
            dot.cornerRadius = size / 2
            dot.backgroundColor = UIColor(white: 1, alpha: CGFloat.random(in: 0.3...0.9, using: &rng)).cgColor

            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values      = [dot.opacity, 0.08, Double.random(in: 0.5...1.0, using: &rng), 0.08, dot.opacity]
            anim.keyTimes    = [0, 0.25, 0.5, 0.75, 1]
            anim.duration    = Double.random(in: 2.5...7.0, using: &rng)
            anim.beginTime   = CACurrentMediaTime() + Double.random(in: 0...6.0, using: &rng)
            anim.repeatCount = .infinity
            dot.add(anim, forKey: "twinkle")
            starLayer.addSublayer(dot)
        }
        layer.addSublayer(starLayer)
    }

    private func starImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            ctx.cgContext.setFillColor(UIColor.white.cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    // MARK: - Moving Clouds (photo-based)

    private func buildMovingClouds() {
        // Immediate sky-gradient placeholder shown while the photo loads
        let sky = CAGradientLayer()
        sky.frame = bounds
        sky.colors = [
            UIColor(red: 0.44, green: 0.70, blue: 0.96, alpha: 1).cgColor,
            UIColor(red: 0.74, green: 0.89, blue: 1.00, alpha: 1).cgColor,
        ]
        sky.startPoint = CGPoint(x: 0.5, y: 0)
        sky.endPoint   = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(sky)

        // Fetch the photo (URLSession uses its built-in disk cache automatically)
        fetchCloudPhoto { [weak self] image in
            guard let self else { return }
            self.installCloudPhoto(image)
            if self.isAnimating { self.startCloudDisplayLink() }
        }
    }

    private func fetchCloudPhoto(completion: @escaping (UIImage) -> Void) {
        let request = URLRequest(
            url: LiveBackgroundView.cloudPhotoURL,
            cachePolicy: .returnCacheDataElseLoad,  // serve instantly on repeat opens
            timeoutInterval: 15
        )
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }

    /// Places two copies of the photo side-by-side, scaled to fill height, ready for seamless scrolling.
    private func installCloudPhoto(_ image: UIImage) {
        guard bounds.height > 0 else { return }

        // Scale so the image fills the full height of the view
        let scale = bounds.height / image.size.height
        let scaledW = ceil(image.size.width * scale)
        cloudScrollWidth = scaledW

        for i in 0..<2 {
            let iv = UIImageView(image: image)
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.frame = CGRect(x: CGFloat(i) * scaledW, y: 0, width: scaledW, height: bounds.height)
            addSubview(iv)
            cloudImageViews.append(iv)
        }
    }

    // MARK: - Cloud scroll loop

    private func startCloudDisplayLink() {
        cloudDisplayLink?.invalidate()
        lastCloudTick = 0
        let dl = CADisplayLink(target: self, selector: #selector(tickClouds))
        dl.add(to: .main, forMode: .common)
        cloudDisplayLink = dl
    }

    @objc private func tickClouds(_ dl: CADisplayLink) {
        if lastCloudTick == 0 { lastCloudTick = dl.timestamp; return }
        let dt = CGFloat(dl.timestamp - lastCloudTick)
        lastCloudTick = dl.timestamp
        let step = LiveBackgroundView.cloudScrollSpeed * dt

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for iv in cloudImageViews {
            iv.frame.origin.x -= step
            // Leapfrog: once a tile has fully scrolled off the left, jump it to the right
            if iv.frame.maxX <= 0 {
                iv.frame.origin.x += cloudScrollWidth * CGFloat(cloudImageViews.count)
            }
        }
        CATransaction.commit()
    }
}
