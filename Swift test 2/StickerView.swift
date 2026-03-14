import SwiftUI
import UIKit
import Vision
import CoreImage

// MARK: - Coordinator

final class StickerCoordinator: NSObject, UIGestureRecognizerDelegate {
    var sticker: Binding<Sticker>
    let onTapSelect: () -> Void
    var onGestureStart: (() -> Void)?
    var onGestureEnd: (() -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?   // screen-space position while dragging
    var onDragEnded: ((CGPoint) -> Void)?     // screen-space position on release
    var onLongPress: (() -> Void)?            // override for long-press (e.g. text re-edit)
    var onDoubleTap: (() -> Void)?            // double-tap to enter lasso mode
    weak var panGesture: UIPanGestureRecognizer?
    var isGesturing = false

    private var panStartPosition: CGPoint = .zero
    private var pinchStartScale: CGFloat = 1.0
    private var rotateStartAngle: Double = 0.0

    init(sticker: Binding<Sticker>, onTapSelect: @escaping () -> Void) {
        self.sticker = sticker
        self.onTapSelect = onTapSelect
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return gr.view === other.view
    }

    @objc func handleTap(_ gr: UITapGestureRecognizer) {
        onTapSelect()
    }

    @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        onDoubleTap?()
    }

    @objc func handlePan(_ gr: UIPanGestureRecognizer) {
        guard let view = gr.view else { return }
        switch gr.state {
        case .began:
            isGesturing = true
            onGestureStart?()
            panStartPosition = view.center
            gr.setTranslation(.zero, in: view.superview)
        case .changed:
            let t = gr.translation(in: view.superview)
            view.center = CGPoint(
                x: panStartPosition.x + t.x,
                y: panStartPosition.y + t.y
            )
            sticker.wrappedValue.position = view.center
            // Report screen-space location for trash zone detection
            let screenPos = view.convert(CGPoint.zero, to: nil)
            onDragChanged?(screenPos)
        case .ended, .cancelled, .failed:
            isGesturing = false
            let screenPos = view.convert(CGPoint.zero, to: nil)
            onDragEnded?(screenPos)
            onGestureEnd?()
        default:
            break
        }
    }

    @objc func handlePinch(_ gr: UIPinchGestureRecognizer) {
        guard let view = gr.view else { return }
        switch gr.state {
        case .began:
            isGesturing = true
            onGestureStart?()
            pinchStartScale = sticker.wrappedValue.scale
        case .changed:
            let newScale = max(0.2, min(5.0, pinchStartScale * gr.scale))
            sticker.wrappedValue.scale = newScale
            view.transform = CGAffineTransform(rotationAngle: sticker.wrappedValue.rotation.radians)
                .scaledBy(x: newScale, y: newScale)
        case .ended, .cancelled, .failed:
            isGesturing = false
            onGestureEnd?()
        default:
            break
        }
    }

    @objc func handleRotate(_ gr: UIRotationGestureRecognizer) {
        guard let view = gr.view else { return }
        switch gr.state {
        case .began:
            isGesturing = true
            onGestureStart?()
            rotateStartAngle = sticker.wrappedValue.rotation.radians
        case .changed:
            let newAngle = rotateStartAngle + gr.rotation
            sticker.wrappedValue.rotation = .init(radians: newAngle)
            view.transform = CGAffineTransform(rotationAngle: newAngle)
                .scaledBy(x: sticker.wrappedValue.scale, y: sticker.wrappedValue.scale)
        case .ended, .cancelled, .failed:
            isGesturing = false
            onGestureEnd?()
        default:
            break
        }
    }

    @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        if let onLongPress {
            onLongPress()
        } else {
            let touchPoint = gr.location(in: gr.view)
            Task { await smartRemoveBackground(touchPoint: touchPoint, on: gr.view) }
        }
    }

    /// Tries nature segmentation at the touch point first; falls back to Vision foreground mask.
    @MainActor
    private func smartRemoveBackground(touchPoint: CGPoint, on view: UIView?) async {
        guard case .photo(let currentImage) = sticker.wrappedValue.kind else { return }

        // Show spinner so the user knows processing is happening
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.center = CGPoint(x: 0, y: 0)
        view?.addSubview(spinner)
        spinner.startAnimating()
        defer {
            spinner.stopAnimating()
            spinner.removeFromSuperview()
        }

        let source = currentImage.normalized()
        let imagePoint = viewPointToImagePoint(touchPoint, image: source)

        if let natureResult = await NatureSegmentationProcessor.shared.extractNature(
            from: source, at: imagePoint
        ) {
            sticker.wrappedValue.kind = .photo(natureResult)
            return
        }

        await removeBackground()
    }

    /// Converts a point in StickerUIView coordinate space (origin at center, ±110pt)
    /// to pixel coordinates in the given image.
    private func viewPointToImagePoint(_ point: CGPoint, image: UIImage) -> CGPoint {
        guard let cg = image.cgImage else { return point }
        let viewSize = CGSize(width: 220, height: 220)
        let imgSize  = CGSize(width: cg.width, height: cg.height)
        let scale    = min(viewSize.width / imgSize.width, viewSize.height / imgSize.height)
        let drawSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
        let drawOrigin = CGPoint(
            x: (viewSize.width  - drawSize.width)  / 2,
            y: (viewSize.height - drawSize.height) / 2
        )
        // StickerUIView bounds origin is (-110, -110), so shift to 0-based space
        let local = CGPoint(x: point.x + 110, y: point.y + 110)
        return CGPoint(
            x: (local.x - drawOrigin.x) / scale,
            y: (local.y - drawOrigin.y) / scale
        )
    }

    @MainActor
    private func removeBackground() async {
        guard #available(iOS 17.0, *) else { return }
        guard case .photo(let currentImage) = sticker.wrappedValue.kind else { return }
        let source = currentImage.normalized()
        guard let ciImage = CIImage(image: source) else { return }

        let cutout: UIImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
                guard (try? handler.perform([request])) != nil,
                      let observation = request.results?.first,
                      let maskedBuffer = try? observation.generateMaskedImage(
                          ofInstances: observation.allInstances,
                          from: handler,
                          croppedToInstancesExtent: false
                      )
                else { continuation.resume(returning: nil); return }

                let outCI = CIImage(cvPixelBuffer: maskedBuffer)
                let ctx = CIContext()
                guard let cg = ctx.createCGImage(outCI, from: outCI.extent) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: UIImage(cgImage: cg, scale: source.scale, orientation: .up))
            }
        }

        guard let cutout else { return }
        sticker.wrappedValue.kind = .photo(cutout)
    }
}

// MARK: - StickerUIView

final class StickerUIView: UIView {
    let imageView = UIImageView()
    private let border = UIView()
    private weak var coordinator: StickerCoordinator?
    var usesBoundingBoxHitTest = false

    init(coordinator: StickerCoordinator) {
        self.coordinator = coordinator
        super.init(frame: CGRect(x: 0, y: 0, width: 220, height: 220))
        // .position() in SwiftUI sets center, so anchor here too
        bounds = CGRect(x: -110, y: -110, width: 220, height: 220)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(x: -110, y: -110, width: 220, height: 220)
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        border.frame = CGRect(x: -106, y: -106, width: 212, height: 212)
        border.layer.borderColor = UIColor.systemBlue.cgColor
        border.layer.borderWidth = 2
        border.layer.cornerRadius = 14
        border.isUserInteractionEnabled = false
        addSubview(border)

        layer.shadowRadius = 6
        layer.shadowOpacity = 0.3
        layer.shadowOffset = .zero
        layer.shadowColor = UIColor.black.cgColor

        guard let coord = coordinator else { return }

        let tap = UITapGestureRecognizer(target: coord, action: #selector(StickerCoordinator.handleTap))
        let doubleTap = UITapGestureRecognizer(target: coord, action: #selector(StickerCoordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        let pan = UIPanGestureRecognizer(target: coord, action: #selector(StickerCoordinator.handlePan))
        let pinch = UIPinchGestureRecognizer(target: coord, action: #selector(StickerCoordinator.handlePinch))
        let rotate = UIRotationGestureRecognizer(target: coord, action: #selector(StickerCoordinator.handleRotate))
        let longPress = UILongPressGestureRecognizer(target: coord, action: #selector(StickerCoordinator.handleLongPress))
        longPress.minimumPressDuration = 0.4

        pan.delegate = coord
        pinch.delegate = coord
        rotate.delegate = coord
        coord.panGesture = pan

        for g in [tap, doubleTap, pan, pinch, rotate, longPress] {
            addGestureRecognizer(g)
        }
    }

    func configure(image: UIImage, isSelected: Bool) {
        if let frames = image.images, !frames.isEmpty {
            // Animated GIF — drive UIImageView's built-in frame animation
            if imageView.animationImages?.first !== frames.first {
                imageView.animationImages   = frames
                imageView.animationDuration = image.duration
                imageView.image             = frames[0]   // poster frame while setting up
            }
            if !imageView.isAnimating { imageView.startAnimating() }
        } else {
            // Static image
            if imageView.image !== image {
                imageView.stopAnimating()
                imageView.animationImages = nil
                imageView.image = image
            }
        }
        border.isHidden = !isSelected
        layer.shadowRadius = isSelected ? 10 : 6
        coordinator?.panGesture?.isEnabled = isSelected
    }

    // Hit-test only on non-transparent pixels (skipped for text stickers)
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if usesBoundingBoxHitTest { return super.point(inside: point, with: event) }
        guard let image = imageView.image, let cgImage = image.cgImage else {
            return super.point(inside: point, with: event)
        }

        let viewSize = CGSize(width: 220, height: 220)
        let imgSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scale = min(viewSize.width / imgSize.width, viewSize.height / imgSize.height)
        let drawSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)

        // Convert from centered-origin bounds space to 0-based for pixel lookup
        let localPoint = CGPoint(x: point.x + 110, y: point.y + 110)
        let drawOrigin = CGPoint(x: (viewSize.width - drawSize.width) / 2,
                                 y: (viewSize.height - drawSize.height) / 2)
        let drawRect = CGRect(origin: drawOrigin, size: drawSize)
        guard drawRect.contains(localPoint) else { return false }

        let px = Int((localPoint.x - drawOrigin.x) / scale)
        let py = Int((localPoint.y - drawOrigin.y) / scale)
        guard px >= 0, py >= 0, px < cgImage.width, py < cgImage.height else { return false }

        guard let ctx = CGContext(data: nil, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }

        ctx.draw(cgImage, in: CGRect(x: -px, y: -(cgImage.height - py - 1),
                                     width: cgImage.width, height: cgImage.height))
        guard let data = ctx.data else { return true }
        let alpha = data.load(fromByteOffset: 3, as: UInt8.self)
        return alpha > 10
    }
}
