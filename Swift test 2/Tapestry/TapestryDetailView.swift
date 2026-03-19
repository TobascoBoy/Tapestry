import SwiftUI

// MARK: - TapestryDetailView

struct TapestryDetailView: View {
    let tapestry: Tapestry
    var onDismiss: (() -> Void)? = nil

    @Environment(TapestryStore.self) private var store

    @State private var dragOffset: CGFloat = 0

    /// Only drags that *begin* inside this strip (from the physical left edge) trigger dismiss.
    private let edgeZoneWidth: CGFloat = 22
    private let screenW = UIScreen.main.bounds.width

    /// Dismiss if the user drags past 45 % of the screen OR flicks fast enough.
    private var dismissThreshold: CGFloat { screenW * 0.45 }

    var body: some View {
        let mode = store.canvasMode(for: tapestry.id)

        ZStack(alignment: .leading) {
            // ── Main content ────────────────────────────────────────────────
            NavigationStack {
                StickerCanvasView(
                    tapestryID: tapestry.id,
                    initialCanvasData: tapestry.canvasData,
                    canvasMode: mode,
                    isCollaborative: tapestry.type == .group,
                    isOwner: tapestry.ownerID == nil || tapestry.ownerID == store.currentUserID,
                    onDismiss: onDismiss
                )
                .navigationTitle(tapestry.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            }

            // ── Edge-only dismiss strip ──────────────────────────────────────
            // This transparent overlay covers only the leftmost `edgeZoneWidth` pts.
            // Because it sits on top in the ZStack it intercepts touches that start
            // at the physical edge, leaving all other canvas touches untouched.
            Color.clear
                .frame(width: edgeZoneWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .global)
                        .onChanged { value in
                            // Only track rightward movement.
                            guard value.translation.width > 0 else { return }
                            dragOffset = value.translation.width
                        }
                        .onEnded { value in
                            let swipedFarEnough = value.translation.width > dismissThreshold
                            let flickedFast     = value.predictedEndTranslation.width > screenW * 0.75
                            if swipedFarEnough || flickedFast {
                                withAnimation(.easeOut(duration: 0.25)) { dragOffset = screenW }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    onDismiss?()
                                }
                            } else {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
        }
        // Slide the whole view (including nav bar) with the drag.
        .offset(x: max(0, dragOffset))
        // Progressive left-edge shadow gives the Snapchat-style depth effect.
        .shadow(
            color: .black.opacity(Double(min(dragOffset / screenW, 1)) * 0.45),
            radius: 14, x: -10, y: 0
        )
    }
}
