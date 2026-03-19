import SwiftUI
import UIKit

// MARK: - Canvas constant

let canvasSize: CGFloat = 2000

// MARK: - CanvasHostView

struct CanvasHostView: UIViewRepresentable {
    @Binding var stickers: [Sticker]
    @Binding var selectedStickerID: UUID?
    @Binding var canvasScale: CGFloat
    @Binding var canvasOffset: CGSize
    let canvasBackground: CanvasBackground
    let canvasMode: CanvasMode
    let onTapEmpty: () -> Void
    let onTapSticker: (UUID) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint, UUID) -> Void
    let onStickerGestureStart: () -> Void
    var onStickerGestureEnded: ((UUID) -> Void)? = nil
    let onTextEdit: (UUID) -> Void
    var onPhotoReplaced: ((UUID, UIImage) -> Void)? = nil
    var onViewReady: ((CanvasUIView) -> Void)? = nil

    func makeCoordinator() -> CanvasCoordinator {
        CanvasCoordinator(
            stickers: $stickers,
            selectedStickerID: $selectedStickerID,
            canvasScale: $canvasScale,
            canvasOffset: $canvasOffset,
            onTapEmpty: onTapEmpty,
            onTapSticker: onTapSticker
        )
    }

    func makeUIView(context: Context) -> CanvasUIView {
        let view = CanvasUIView(coordinator: context.coordinator, mode: canvasMode)
        context.coordinator.onDoubleTap = { [weak view] stickerID in
            view?.enterLassoMode(stickerID: stickerID)
        }
        onViewReady?(view)
        return view
    }

    func updateUIView(_ view: CanvasUIView, context: Context) {
        context.coordinator.stickers = $stickers
        context.coordinator.selectedStickerID = $selectedStickerID
        context.coordinator.onTapEmpty = onTapEmpty
        context.coordinator.onTapSticker = onTapSticker
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onStickerGestureStart = onStickerGestureStart
        context.coordinator.onStickerGestureEnded = onStickerGestureEnded
        context.coordinator.onTextEdit = onTextEdit
        context.coordinator.onPhotoReplaced = onPhotoReplaced

        view.syncBackground(canvasBackground)
        view.applyCanvasTransform(scale: canvasScale, offset: canvasOffset)
        view.syncStickersIfNeeded(stickers: stickers, selectedID: selectedStickerID)
    }
}

// MARK: - CanvasCoordinator

final class CanvasCoordinator: NSObject, UIGestureRecognizerDelegate {
    var stickers: Binding<[Sticker]>
    var selectedStickerID: Binding<UUID?>
    var canvasScale: Binding<CGFloat>
    var canvasOffset: Binding<CGSize>
    var onTapEmpty: () -> Void
    var onTapSticker: (UUID) -> Void
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint, UUID) -> Void)?
    var onStickerGestureStart: (() -> Void)?
    var onStickerGestureEnded: ((UUID) -> Void)?
    var onTextEdit: ((UUID) -> Void)?
    var onDoubleTap: ((UUID) -> Void)?
    var onPhotoReplaced: ((UUID, UIImage) -> Void)?
    weak var canvasView: UIView?
    weak var canvasPan: UIPanGestureRecognizer?
    weak var canvasPinch: UIPinchGestureRecognizer?
    var isLassoActive: Bool = false

    private var panStartOffset: CGSize = .zero
    private var pinchStartScale: CGFloat = 1.0

    init(stickers: Binding<[Sticker]>, selectedStickerID: Binding<UUID?>,
         canvasScale: Binding<CGFloat>, canvasOffset: Binding<CGSize>,
         onTapEmpty: @escaping () -> Void, onTapSticker: @escaping (UUID) -> Void) {
        self.stickers = stickers
        self.selectedStickerID = selectedStickerID
        self.canvasScale = canvasScale
        self.canvasOffset = canvasOffset
        self.onTapEmpty = onTapEmpty
        self.onTapSticker = onTapSticker
    }

    func centerCanvasIfNeeded(in bounds: CGRect) {
        guard canvasOffset.wrappedValue == .zero, let cv = canvasView else { return }
        cv.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func bindingForSticker(id: UUID) -> Binding<Sticker> {
        Binding(
            get: {
                if let found = self.stickers.wrappedValue.first(where: { $0.id == id }) { return found }
                return Sticker(kind: .photo(UIImage()), position: .zero, scale: 1, rotation: .zero, zIndex: 0)
            },
            set: { newValue in
                guard let idx = self.stickers.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
                self.stickers.wrappedValue[idx] = newValue
            }
        )
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc func handleCanvasTap(_ gr: UITapGestureRecognizer) { onTapEmpty() }

    @objc func handleCanvasPan(_ gr: UIPanGestureRecognizer) {
        guard let view = gr.view else { return }
        switch gr.state {
        case .began:   panStartOffset = canvasOffset.wrappedValue
        case .changed:
            let t = gr.translation(in: view)
            canvasOffset.wrappedValue = CGSize(width: panStartOffset.width + t.x,
                                               height: panStartOffset.height + t.y)
        default: break
        }
    }

    @objc func handleCanvasPinch(_ gr: UIPinchGestureRecognizer) {
        switch gr.state {
        case .began:   pinchStartScale = canvasScale.wrappedValue
        case .changed: canvasScale.wrappedValue = min(max(pinchStartScale * gr.scale, 0.25), 4.0)
        default: break
        }
    }
}

