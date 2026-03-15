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
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        PersonSegmentationWarmup.isWarmedUp = true
        print("[PersonSegmentation] model warmed up")
    }

    private func makeTinyImage() -> CGImage? {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
            .image { ctx in UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16)) }
            .cgImage
    }
}
