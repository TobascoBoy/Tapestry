import SwiftUI

struct TapestryDetailView: View {
    let tapestry: Tapestry
    var onDismiss: (() -> Void)? = nil

    @Environment(TapestryStore.self) private var store

    var body: some View {
        let mode = store.canvasMode(for: tapestry.id)
        NavigationStack {
            StickerCanvasView(tapestryID: tapestry.id, initialCanvasData: tapestry.canvasData, canvasMode: mode)
                .navigationTitle(tapestry.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbar {
                    if let onDismiss {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation(.easeOut(duration: 0.22)) { onDismiss() }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left").fontWeight(.semibold)
                                    Text("Profile")
                                }
                            }
                        }
                    }
                }
        }
    }
}
