import UIKit

// URL needs to be Identifiable to use .sheet(item:) throughout the app
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension UIImage {
    /// Redraws the image so its orientation is always `.up`.
    /// Needed before passing images to Vision or VisionKit to avoid rotation artifacts.
    func normalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized ?? self
    }


}
