import UIKit
import CoreImage

/// Generates a subject-silhouette outline using Core Image morphology —
/// the same technique Apple uses for the iOS sticker-lift outline effect.
///
/// Pipeline:  binarize alpha → dilate → subtract original → tint solid color
enum SubjectOutlineGenerator {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Photo outline (CGImage → UIImage, one-shot, cached by caller)

    static func generateOutlineImage(cgImage: CGImage,
                                     color: UIColor,
                                     targetPointWidth: CGFloat = 1.5) -> UIImage? {
        let longerSide = CGFloat(max(cgImage.width, cgImage.height))
        let radius = max(1.0, targetPointWidth * longerSide / 220)
        let ci = CIImage(cgImage: cgImage)
        guard let outlineCI = buildOutlineCI(from: ci, color: color, radius: radius) else { return nil }
        guard let cg = ciContext.createCGImage(outlineCI, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Shared CI pipeline (used by both photo and video paths)

    /// Builds the outline CIImage lazily — nothing is rendered until the caller
    /// commits a Metal command buffer or calls createCGImage.
    ///
    /// - Parameters:
    ///   - input:  Source CIImage (photo or video frame).
    ///   - color:  Desired outline color.
    ///   - radius: Dilation radius **in pixels of `input`**. Compute as
    ///             `max(1, targetPt * pixelsPerPoint)` before calling.
    static func buildOutlineCI(from input: CIImage,
                                color: UIColor,
                                radius: CGFloat) -> CIImage? {
        // 1. Binarize alpha: snap soft/antialiased edges to hard 0 or 1 so dilation
        //    produces a uniform ring instead of a grainy gradient.
        let binarized = input
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 100)
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

        // 2. Expand silhouette outward.
        let expanded = binarized.applyingFilter("CIMorphologyMaximum",
                                                parameters: ["inputRadius": radius])

        // 3. Ring = expanded pixels NOT in original binary mask.
        let ring = expanded.applyingFilter("CISourceOutCompositing",
                                           parameters: ["inputBackgroundImage": binarized])

        // 4. Tint to solid color (CIColorMatrix: output.rgb = color × ring.alpha premultiplied).
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return ring.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: r),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: g),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: b),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)
        ])
    }
}
