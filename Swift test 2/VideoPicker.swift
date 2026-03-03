import SwiftUI
import PhotosUI
import AVFoundation

// MARK: - VideoPicker
// Wraps PHPickerViewController filtered to videos.
// Copies the picked video to a temp file and returns its URL.

struct VideoPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let item = results.first?.itemProvider,
                  item.hasItemConformingToTypeIdentifier("public.movie") else { return }

            item.loadFileRepresentation(forTypeIdentifier: "public.movie") { url, error in
                guard let url else { return }
                // Copy to temp dir so the file persists after the picker closes
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                try? FileManager.default.copyItem(at: url, to: dest)
                DispatchQueue.main.async { self.onPick(dest) }
            }
        }
    }
}
