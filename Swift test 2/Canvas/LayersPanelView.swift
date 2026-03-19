import SwiftUI

// MARK: - LayersPanelView

struct LayersPanelView: View {
    let stickers: [Sticker]
    let onSelect:  (UUID) -> Void
    let onDismiss: () -> Void
    let onReorder: ([UUID]) -> Void   // ordered top → bottom

    @State private var localOrder: [Sticker] = []
    @State private var draggingID: UUID?      = nil
    @State private var dragOffset: CGFloat    = 0

    private let rowHeight: CGFloat = 68

    var body: some View {
        // VStack intentionally has NO .ignoresSafeArea so content starts below
        // the navigation bar. Only the background extends behind safe areas.
        VStack(alignment: .leading, spacing: 0) {

            if localOrder.isEmpty {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(localOrder.enumerated()), id: \.element.id) { idx, sticker in
                            rowView(sticker: sticker, index: idx)
                                .zIndex(draggingID == sticker.id ? 10 : 0)

                            if idx < localOrder.count - 1 {
                                Divider()
                                    .overlay(Color.white.opacity(0.08))
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }
                // Prevent UIScrollView from interfering while a row is being dragged.
                .scrollDisabled(draggingID != nil)
            }
        }
        .frame(width: UIScreen.main.bounds.width * 0.25)
        .frame(maxHeight: .infinity)
        // Background fills behind nav bar / home indicator; VStack content does not.
        .background {
            Rectangle()
                .fill(.thinMaterial)
                .ignoresSafeArea(edges: .vertical)
        }
        .onAppear {
            localOrder = stickers.sorted { $0.zIndex > $1.zIndex }
        }
        .onChange(of: stickers.map(\.id)) { _, _ in
            guard draggingID == nil else { return }
            let updated: [Sticker] = localOrder.compactMap { old in
                stickers.first(where: { $0.id == old.id })
            }
            let existing = Set(updated.map(\.id))
            let added = stickers
                .filter { !existing.contains($0.id) }
                .sorted { $0.zIndex > $1.zIndex }
            localOrder = added + updated
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func rowView(sticker: Sticker, index: Int) -> some View {
        let isDragging = draggingID == sticker.id

        ThumbnailView(sticker: sticker)
            .frame(height: rowHeight)
            .scaleEffect(isDragging ? 1.06 : 1.0)
            .shadow(color: isDragging ? .black.opacity(0.35) : .clear, radius: 10, y: 5)
            .offset(y: rowOffset(for: index))
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: draggingID)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.8), value: dragOffset)
            // Tap = select
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSelect(sticker.id)
            }
            // Long-press + drag handled by a UIKit recognizer so that UIScrollView
            // can still cancel it during a scroll attempt (SwiftUI gesture wrappers
            // prevent that cancellation, which is why the list could never scroll).
            .overlay {
                RowReorderGesture(
                    stickerID: sticker.id,
                    draggingID: $draggingID,
                    dragOffset: $dragOffset,
                    onCommit: commitReorder
                )
            }
    }

    // MARK: - Drag math

    private func rowOffset(for index: Int) -> CGFloat {
        guard let did = draggingID,
              let dragIdx = localOrder.firstIndex(where: { $0.id == did })
        else { return 0 }

        if localOrder[index].id == did { return dragOffset }

        let target = clampedTarget(from: dragIdx)
        if dragIdx < target, index > dragIdx, index <= target { return -rowHeight }
        if dragIdx > target, index >= target, index < dragIdx { return  rowHeight }
        return 0
    }

    private func clampedTarget(from dragIdx: Int) -> Int {
        let raw = dragIdx + Int((dragOffset / rowHeight).rounded())
        return max(0, min(localOrder.count - 1, raw))
    }

    private func commitReorder() {
        guard let did = draggingID,
              let dragIdx = localOrder.firstIndex(where: { $0.id == did })
        else { draggingID = nil; dragOffset = 0; return }

        let target = clampedTarget(from: dragIdx)
        var newOrder = localOrder
        let item = newOrder.remove(at: dragIdx)
        newOrder.insert(item, at: target)

        withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
            localOrder = newOrder
            draggingID = nil
            dragOffset = 0
        }
        onReorder(newOrder.map(\.id))
    }
}

// MARK: - RowReorderGesture (UIKit-backed)
//
// Why UIKit instead of SwiftUI gestures?
//
// SwiftUI wraps DragGesture (and any SequenceGesture that contains one) in a
// UIGestureRecognizer that opts out of UIScrollView's touch-cancellation system.
// UIScrollView cancels content-view touches when it decides a scroll is beginning,
// but SwiftUI's wrapper ignores that cancellation — so the scroll never starts.
//
// UILongPressGestureRecognizer is a first-class UIKit recognizer that UIScrollView
// CAN cancel: fast swipes cancel the long press and the scroll proceeds normally.
// After the long press fires (.began), .changed events track finger movement —
// no separate DragGesture is needed at all.

private struct RowReorderGesture: UIViewRepresentable {
    let stickerID: UUID
    @Binding var draggingID: UUID?
    @Binding var dragOffset: CGFloat
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let gr = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        gr.minimumPressDuration = 0.4
        // Don't block taps from reaching the SwiftUI .onTapGesture below.
        gr.cancelsTouchesInView = false
        view.addGestureRecognizer(gr)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: RowReorderGesture
        private var startY: CGFloat = 0

        init(_ parent: RowReorderGesture) { self.parent = parent }

        @objc func handle(_ gr: UILongPressGestureRecognizer) {
            // All UIKit gesture callbacks arrive on the main thread.
            switch gr.state {
            case .began:
                startY = gr.location(in: gr.view).y
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    parent.draggingID = parent.stickerID
                    parent.dragOffset = 0
                }

            case .changed:
                guard parent.draggingID == parent.stickerID else { return }
                // location(in:) returns coordinates outside view bounds while dragging,
                // so the delta correctly represents movement past neighbouring rows.
                parent.dragOffset = gr.location(in: gr.view).y - startY

            case .ended, .cancelled:
                guard parent.draggingID == parent.stickerID else { return }
                parent.onCommit()

            default:
                break
            }
        }
    }
}

// MARK: - ThumbnailView

private struct ThumbnailView: View {
    let sticker: Sticker

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.2, opacity: 0.6))

            content
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch sticker.kind {
        case .photo(let img):
            Image(uiImage: img)
                .resizable()
                .scaledToFit()

        case .text(let c):
            ZStack {
                Color(white: 0.18)
                Image(uiImage: c.image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }

        case .music(let track):
            if let art = track.artworkImage {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFit()
            } else {
                LinearGradient(colors: [.purple.opacity(0.7), .blue.opacity(0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                    )
            }

        case .video(_, let thumbnail, _):
            ZStack {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                Circle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 18, height: 18)
                Image(systemName: "play.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.white)
            }
        }
    }
}
