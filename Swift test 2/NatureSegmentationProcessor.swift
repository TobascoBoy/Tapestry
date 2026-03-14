import CoreML
import UIKit
import CoreImage

// MARK: - NatureSegmentationProcessor

final class NatureSegmentationProcessor {
    static let shared = NatureSegmentationProcessor()

    // ADE20K 0-indexed class labels for nature/landscape
    private static let natureClasses: Set<Int32> = [
        2,    // sky
        4,    // tree
        9,    // grass
        16,   // mountain, mount
        21,   // water
        26,   // sea
        29,   // field
        34,   // rock, stone
        46,   // sand
        60,   // river, stream
        66,   // flower
        68,   // hill
        72,   // palm tree
        94,   // land, ground, soil
        113,  // waterfall
        128   // lake
    ]

    private let model: NatureSegmenter

    private init() {
        guard let m = try? NatureSegmenter() else {
            fatalError("NatureSegmenter.mlpackage not found in bundle")
        }
        model = m
    }

    /// Runs SegFormer-B2 segmentation on `image`. If the pixel at `imagePoint`
    /// (in image pixel coordinates) belongs to a nature class, returns a cutout
    /// UIImage with only that semantic region visible (transparent elsewhere).
    /// Returns nil if the touch point is not on a nature class.
    func extractNature(from image: UIImage, at imagePoint: CGPoint) async -> UIImage? {
        let source = image.normalized()
        print("[NatureSegmenter] image size: \(source.size), scale: \(source.scale), imagePoint: \(imagePoint)")

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                guard let pixelBuffer = source.toModelPixelBuffer() else {
                    print("[NatureSegmenter] ❌ pixelBuffer creation failed")
                    continuation.resume(returning: nil)
                    return
                }
                guard let output = try? self.model.prediction(image: pixelBuffer) else {
                    print("[NatureSegmenter] ❌ model prediction failed")
                    continuation.resume(returning: nil)
                    return
                }

                let classMap = output.classMap  // MLMultiArray [512, 512], Float32
                print("[NatureSegmenter] classMap shape: \(classMap.shape), dataType: \(classMap.dataType.rawValue)")
                let floatPtr = classMap.dataPointer.assumingMemoryBound(to: Float16.self)

                // Scale touch point → model coordinate space
                let sx = 512.0 / source.size.width
                let sy = 512.0 / source.size.height
                let mx = max(0, min(511, Int(imagePoint.x * sx)))
                let my = max(0, min(511, Int(imagePoint.y * sy)))

                let classAtPoint = Int32(floatPtr[my * 512 + mx])
                print("[NatureSegmenter] modelPoint: (\(mx), \(my)), classAtPoint: \(classAtPoint), isNature: \(Self.natureClasses.contains(classAtPoint))")

                guard Self.natureClasses.contains(classAtPoint) else {
                    continuation.resume(returning: nil)
                    return
                }

                let mask = Self.buildMask(floatPtr: floatPtr, targetClass: classAtPoint)
                continuation.resume(returning: Self.applyMask(mask, to: source))
            }
        }
    }

    // MARK: - Private helpers

    /// Builds a 512×512 grayscale CIImage — white where label == targetClass, black elsewhere.
    private static func buildMask(floatPtr: UnsafeMutablePointer<Float16>, targetClass: Int32) -> CIImage {
        var bytes = [UInt8](repeating: 0, count: 512 * 512)
        for i in 0..<(512 * 512) {
            bytes[i] = Int32(floatPtr[i]) == targetClass ? 255 : 0
        }
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let cgMask = CGImage(
            width: 512, height: 512,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 512,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )!
        return CIImage(cgImage: cgMask)
    }

    /// Composites `image` using `mask` as the alpha channel — transparent where mask is black.
    private static func applyMask(_ mask: CIImage, to image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }

        let scaleX = ciImage.extent.width / 512
        let scaleY = ciImage.extent.height / 512
        let scaledMask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(
            CIImage(color: .clear).cropped(to: ciImage.extent),
            forKey: kCIInputBackgroundImageKey
        )
        filter.setValue(scaledMask, forKey: kCIInputMaskImageKey)

        guard let output = filter.outputImage else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(output, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }
}

// MARK: - UIImage → CVPixelBuffer

private extension UIImage {
    /// Draws the image into a 512×512 BGRA pixel buffer for CoreML input.
    func toModelPixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, 512, 512,
            kCVPixelFormatType_32BGRA, attrs, &buffer
        ) == kCVReturnSuccess, let buf = buffer else { return nil }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buf),
            width: 512, height: 512,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cg = cgImage else { return nil }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        return buf
    }
}
