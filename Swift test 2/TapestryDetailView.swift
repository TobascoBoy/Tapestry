import SwiftUI

struct TapestryDetailView: View {
    let tapestry: Tapestry
    var onDismiss: (() -> Void)? = nil

    @Environment(TapestryStore.self) private var store

    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging = false

    private let dismissThreshold: CGFloat = 120

    var body: some View {
        let mode = store.canvasMode(for: tapestry.id)
        NavigationStack {
            StickerCanvasView(tapestryID: tapestry.id, initialCanvasData: tapestry.canvasData, canvasMode: mode)
                .navigationTitle(tapestry.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        .offset(x: max(0, dragOffset))
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .updating($isDragging) { _, state, _ in state = true }
                .onChanged { value in
                    guard value.startLocation.x < 60,
                          value.translation.width > 0 else { return }
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    let shouldDismiss = value.translation.width > dismissThreshold
                        || value.predictedEndTranslation.width > dismissThreshold * 1.5
                    if shouldDismiss, let onDismiss {
                        withAnimation(.easeOut(duration: 0.22)) { dragOffset = UIScreen.main.bounds.width }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onDismiss() }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = 0 }
                    }
                }
        )
    }
}
