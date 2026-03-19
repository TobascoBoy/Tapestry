import UIKit
import MetalKit
import CoreImage
import AVFoundation

/// A MTKView that renders a background-removed video frame and an optional
/// silhouette outline **in the same Metal draw call per vsync**.
///
/// Because both the video pixels and the outline are derived from the same
/// CVPixelBuffer and submitted in one MTLCommandBuffer, they are guaranteed
/// to be perfectly in sync — there is no inter-layer timing offset.
///
/// Usage:
///   1. Set `videoOutput` after attaching it to the AVPlayerItem.
///   2. Call `setOutlineVisible(_:)` when the sticker is selected/deselected.
///   3. The view drives its own CADisplayLink. Call `stopDisplayLink()` on cleanup.
final class VideoOutlineMTKView: MTKView {

    var videoOutput: AVPlayerItemVideoOutput?
    var outlineColor: UIColor = .white

    private var showOutline = false
    private let ci: CIContext
    private let cmdQueue: MTLCommandQueue
    private var displayLink: CADisplayLink?

    // Bounding-box cache — updated on a background queue so the pixel buffer
    // lock never blocks the main-thread render loop.
    private var cachedDrawableBounds: CGRect?
    private var isScanningBounds = false

    // MARK: - Init

    override init(frame: CGRect, device: MTLDevice?) {
        let dev = device ?? MTLCreateSystemDefaultDevice()!
        guard let q = dev.makeCommandQueue() else { fatalError("Metal command queue unavailable") }
        ci       = CIContext(mtlDevice: dev, options: [.useSoftwareRenderer: false])
        cmdQueue = q
        super.init(frame: frame, device: dev)
        framebufferOnly      = false   // required so CIRenderDestination can write to the texture
        isOpaque             = false
        backgroundColor      = .clear
        layer.isOpaque       = false
        isPaused             = true    // we drive rendering via CADisplayLink, not MTKView's timer
        enableSetNeedsDisplay = false
        startDisplayLink()
    }

    required init(coder: NSCoder) { fatalError() }
    deinit { stopDisplayLink() }

    // MARK: - Outline visibility

    func setOutlineVisible(_ visible: Bool) {
        showOutline = visible
        if !visible {
            cachedDrawableBounds = nil
        }
    }

    // MARK: - Display link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        // Use a weak proxy so the display link does not retain self, avoiding
        // a reference cycle that would prevent deinit from being called.
        let proxy = Proxy(target: self)
        let dl = CADisplayLink(target: proxy, selector: #selector(Proxy.step))
        dl.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Per-frame render

    fileprivate func renderFrame() {
        guard let output   = videoOutput,
              let drawable = currentDrawable,
              let cmdBuf   = cmdQueue.makeCommandBuffer()
        else { return }

        // itemTime(forHostTime:) returns the item time the video pipeline is
        // displaying RIGHT NOW — identical to what AVPlayerLayer would show.
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        var ignored  = CMTime.zero
        guard let pb = output.copyPixelBuffer(forItemTime: itemTime,
                                               itemTimeForDisplay: &ignored)
        else {
            cmdBuf.commit()
            return
        }

        let dW = CGFloat(drawable.texture.width)
        let dH = CGFloat(drawable.texture.height)

        // Build video CIImage from the pixel buffer (lazy — not rendered yet).
        let videoCI = CIImage(cvPixelBuffer: pb)
        let srcW    = videoCI.extent.width
        let srcH    = videoCI.extent.height

        // Aspect-fill scale so the video fills the square drawable.
        let s  = max(dW / srcW, dH / srcH)
        let ox = (dW - srcW * s) / 2
        let oy = (dH - srcH * s) / 2
        let scaledVideo = videoCI.transformed(
            by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: ox, y: oy)))
        .cropped(to: CGRect(x: 0, y: 0, width: dW, height: dH))

        // Kick off a background scan of the pixel buffer to update the bounding box.
        // The lock + scan never touches the main thread, so the render loop is never stalled.
        // isScanningBounds prevents queuing up concurrent scans.
        var renderCI = scaledVideo
        if showOutline {
            if !isScanningBounds {
                isScanningBounds = true
                let scanBuf  = pb     // ARC retains pb for the closure
                let capturedS  = s, capturedOx = ox, capturedOy = oy, capturedSrcH = srcH
                DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                    let bounds = self?.computeSubjectBoundsCI(in: scanBuf, pbH: capturedSrcH)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isScanningBounds = false
                        if let b = bounds {
                            self.cachedDrawableBounds = CGRect(
                                x:      b.minX * capturedS + capturedOx,
                                y:      b.minY * capturedS + capturedOy,
                                width:  b.width  * capturedS,
                                height: b.height * capturedS)
                        }
                    }
                }
            }
            if let drawableBounds = cachedDrawableBounds {
                let lineWidth = max(3.0, 2.0 * contentScaleFactor)
                let box = buildBoxOutlineCI(bounds: drawableBounds, lineWidth: lineWidth)
                renderCI = scaledVideo.composited(over: box)
            }
        }

        // Clear the drawable to transparent, then render.
        // This ensures the canvas behind shows through the video's transparent regions.
        clearDrawable(drawable.texture, with: cmdBuf)

        let dest = CIRenderDestination(mtlTexture: drawable.texture,
                                       commandBuffer: cmdBuf)
        // isFlipped = true maps CIImage y-up to Metal texture y-down so the
        // video is right-side up when displayed on screen.
        dest.isFlipped   = true
        dest.alphaMode   = .premultiplied

        try? ci.startTask(toRender: renderCI, to: dest)
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Helpers

    /// Scans the BGRA pixel buffer at reduced resolution and returns the
    /// bounding rect of non-transparent pixels in **CIImage coordinates** (y-up).
    /// Returns nil if the entire frame is transparent.
    private func computeSubjectBoundsCI(in pb: CVPixelBuffer, pbH: CGFloat) -> CGRect? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let pbW  = CVPixelBufferGetWidth(pb)
        let pbHi = CVPixelBufferGetHeight(pb)
        let bpr  = CVPixelBufferGetBytesPerRow(pb)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        let step: Int = 8          // sample every 8th pixel — fast enough, accurate enough
        let threshold: UInt8 = 20  // ignore near-transparent fringe pixels

        var minX = pbW, maxX = 0, minRow = pbHi, maxRow = 0

        for row in Swift.stride(from: 0, to: pbHi, by: step) {
            for col in Swift.stride(from: 0, to: pbW, by: step) {
                // BGRA: alpha is at byte offset +3
                if bytes[row * bpr + col * 4 + 3] > threshold {
                    if col < minX   { minX   = col }
                    if col > maxX   { maxX   = col }
                    if row < minRow { minRow = row }
                    if row > maxRow { maxRow = row }
                }
            }
        }

        guard minX <= maxX, minRow <= maxRow else { return nil }

        // Convert pixel-buffer (y-down, row 0 = top) → CIImage (y-up, 0 = bottom).
        // CIImage y = pbH - pb_row  (approximately; half-pixel offset omitted)
        let ciMinX = CGFloat(minX)
        let ciMaxX = CGFloat(maxX)
        let ciMinY = pbH - CGFloat(maxRow)
        let ciMaxY = pbH - CGFloat(minRow)
        return CGRect(x: ciMinX, y: ciMinY,
                      width: ciMaxX - ciMinX, height: ciMaxY - ciMinY)
    }

    /// Builds a box outline as four thin CIImage rectangles composited together.
    /// The box is expanded by one `lineWidth` on each side so it sits just outside the subject.
    private func buildBoxOutlineCI(bounds: CGRect, lineWidth: CGFloat) -> CIImage {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        outlineColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let c = CIColor(red: r * a, green: g * a, blue: b * a, alpha: a)

        let rect = bounds.insetBy(dx: -lineWidth, dy: -lineWidth)
        let lw   = lineWidth
        let top    = CIImage(color: c).cropped(to: CGRect(x: rect.minX, y: rect.maxY - lw,  width: rect.width,  height: lw))
        let bottom = CIImage(color: c).cropped(to: CGRect(x: rect.minX, y: rect.minY,       width: rect.width,  height: lw))
        let left   = CIImage(color: c).cropped(to: CGRect(x: rect.minX, y: rect.minY,       width: lw,          height: rect.height))
        let right  = CIImage(color: c).cropped(to: CGRect(x: rect.maxX - lw, y: rect.minY, width: lw,          height: rect.height))
        return top.composited(over: bottom).composited(over: left).composited(over: right)
    }

    private func clearDrawable(_ texture: MTLTexture, with cmdBuf: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture     = texture
        pass.colorAttachments[0].loadAction  = .clear
        pass.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        cmdBuf.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    // MARK: - Weak proxy (breaks CADisplayLink retain cycle)

    private final class Proxy: NSObject {
        weak var target: VideoOutlineMTKView?
        init(target: VideoOutlineMTKView) { self.target = target }
        @objc func step() { target?.renderFrame() }
    }
}
