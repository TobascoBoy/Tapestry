import Vision
import UIKit

/// Warms up VNGeneratePersonSegmentationRequest at app launch so the first real
/// inference in video processing doesn't block the thread for 10–30 seconds.
final class PersonSegmentationWarmup {

    static let shared = PersonSegmentationWarmup()

    /// Static so VideoProcessor can read this without triggering lazy `shared` init
    /// (and therefore never blocks the video processing thread).
    static private(set) var isWarmedUp = false

    private init() {
        guard let cgImage = makeTinyImage() else { return }

        // Warm up VNGeneratePersonSegmentationRequest (used by video bg removal)
        let personRequest = VNGeneratePersonSegmentationRequest()
        personRequest.qualityLevel = .balanced
        personRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let personHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? personHandler.perform([personRequest])

        // Warm up VNGenerateForegroundInstanceMaskRequest (used by photo long-press bg removal)
        // Without this, first use freezes the UI for 10–30 seconds.
        if #available(iOS 17.0, *) {
            let fgRequest = VNGenerateForegroundInstanceMaskRequest()
            let fgHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? fgHandler.perform([fgRequest])
        }

        PersonSegmentationWarmup.isWarmedUp = true
        print("[PersonSegmentation] models warmed up")
    }

    private func makeTinyImage() -> CGImage? {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
            .image { ctx in UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16)) }
            .cgImage
    }
}
