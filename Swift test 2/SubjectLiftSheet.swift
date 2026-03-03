import SwiftUI
import UIKit
import VisionKit

// MARK: - SwiftUI Sheet Wrapper

@available(iOS 17.0, *)
struct SubjectLiftSheet: View {
    let image: UIImage
    let onConfirm: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var isSubjectHighlighted = false
    @State private var coordinator: SubjectLiftCoordinator?

    var body: some View {
        ZStack(alignment: .bottom) {
            // The VisionKit image view fills the whole sheet
            SubjectLiftUIView(image: image, onSubjectHighlightChanged: { highlighted in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSubjectHighlighted = highlighted
                }
            }, coordinatorReady: { coord in
                self.coordinator = coord
            })
            .ignoresSafeArea()

            // Confirmation bar slides up once subject is lifted
            if isSubjectHighlighted {
                confirmationBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
    }

    private var confirmationBar: some View {
        VStack(spacing: 0) {
            Text("Use this cutout?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            HStack(spacing: 16) {
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button {
                    Task {
                        if let cutout = await coordinator?.extractCutout() {
                            onConfirm(cutout)
                        }
                    }
                } label: {
                    Text("Use Cutout")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - UIViewRepresentable

@available(iOS 17.0, *)
struct SubjectLiftUIView: UIViewRepresentable {
    let image: UIImage
    let onSubjectHighlightChanged: (Bool) -> Void
    let coordinatorReady: (SubjectLiftCoordinator) -> Void

    func makeCoordinator() -> SubjectLiftCoordinator {
        SubjectLiftCoordinator(
            onSubjectHighlightChanged: onSubjectHighlightChanged
        )
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black

        let imageView = UIImageView()
        imageView.image = image.normalized()
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let interaction = ImageAnalysisInteraction()
        // .imageSubject = subject lifting only, no Live Text clutter
        interaction.preferredInteractionTypes = .imageSubject
        interaction.delegate = context.coordinator
        imageView.addInteraction(interaction)

        context.coordinator.interaction = interaction
        context.coordinator.imageView = imageView

        Task { @MainActor in
            await context.coordinator.analyze(image: image)
            coordinatorReady(context.coordinator)
        }

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Coordinator

@available(iOS 17.0, *)
@MainActor
final class SubjectLiftCoordinator: NSObject, ImageAnalysisInteractionDelegate {
    private let analyzer = ImageAnalyzer()
    weak var imageView: UIImageView?
    var interaction: ImageAnalysisInteraction?

    private let onSubjectHighlightChanged: (Bool) -> Void

    init(onSubjectHighlightChanged: @escaping (Bool) -> Void) {
        self.onSubjectHighlightChanged = onSubjectHighlightChanged
    }

    func analyze(image: UIImage) async {
        guard ImageAnalyzer.isSupported else { return }
        let config = ImageAnalyzer.Configuration([.visualLookUp])
        guard let analysis = try? await analyzer.analyze(image.normalized(), configuration: config) else { return }
        interaction?.analysis = analysis
    }

    /// Called by VisionKit whenever the highlighted subject set changes
    func interaction(
        _ interaction: ImageAnalysisInteraction,
        highlightedSubjectsDidChange highlightedSubjects: Set<ImageAnalysisInteraction.Subject>
    ) {
        onSubjectHighlightChanged(!highlightedSubjects.isEmpty)
    }

    /// Extracts a single UIImage of all currently highlighted subjects
    func extractCutout() async -> UIImage? {
        guard let interaction else { return nil }
        let subjects = interaction.highlightedSubjects
        guard !subjects.isEmpty else { return nil }
        return try? await interaction.image(for: subjects)
    }

    // MARK: - ImageAnalysisInteractionDelegate required geometry bridge

    /// Tells VisionKit where the image sits inside the view, so subject highlight
    /// outlines are drawn in the right coordinates.
    func contentRect(for interaction: ImageAnalysisInteraction) -> CGRect {
        guard let imageView, let image = imageView.image else {
            return imageView?.bounds ?? .zero
        }
        return AVMakeRect(aspectRatio: image.size, insideRect: imageView.bounds)
    }
}

// MARK: - CGRect aspect-fit helper (mirrors AVFoundation's AVMakeRect without the import)

private func AVMakeRect(aspectRatio: CGSize, insideRect boundingRect: CGRect) -> CGRect {
    let widthRatio  = boundingRect.width  / aspectRatio.width
    let heightRatio = boundingRect.height / aspectRatio.height
    let scale = min(widthRatio, heightRatio)
    let size  = CGSize(width: aspectRatio.width * scale, height: aspectRatio.height * scale)
    let origin = CGPoint(
        x: boundingRect.midX - size.width  / 2,
        y: boundingRect.midY - size.height / 2
    )
    return CGRect(origin: origin, size: size)
}
