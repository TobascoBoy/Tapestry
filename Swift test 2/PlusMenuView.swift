import SwiftUI
import UIKit

// MARK: - Menu item enum

enum PlusMenuItem {
    case photo
    case text
    case background
    case music
    case video

    var label: String {
        switch self {
        case .photo:      return "Photo"
        case .text:       return "Text"
        case .background: return "Background"
        case .music:      return "Music"
        case .video:      return "Video"
        }
    }
    var icon: String {
        switch self {
        case .photo:      return "photo.fill"
        case .text:       return "textformat"
        case .background: return "paintpalette.fill"
        case .music:      return "music.note"
        case .video:      return "video.fill"
        }
    }
    var color: Color {
        switch self {
        case .photo:      return .blue
        case .text:       return .teal
        case .background: return .orange
        case .music:      return .pink
        case .video:      return .purple
        }
    }
}

// MARK: - PlusMenuOverlay

struct PlusMenuOverlay: View {
    let onSelect:  (PlusMenuItem) -> Void
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .trailing, spacing: 12) {
                menuRow(.photo,      index: 0)
                menuRow(.text,       index: 1)
                menuRow(.background, index: 2)
                menuRow(.music,      index: 3)
                menuRow(.video,      index: 4)
            }
            .padding(.top, 8)
            .padding(.trailing, 16)
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private func menuRow(_ item: PlusMenuItem, index: Int) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                onSelect(item)
            }
        } label: {
            HStack(spacing: 10) {
                Text(item.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                ZStack {
                    Circle()
                        .fill(item.color)
                        .frame(width: 44, height: 44)
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: item.color.opacity(0.5), radius: 6, y: 3)
            }
        }
        .buttonStyle(.plain)
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : 30)
        .animation(
            .spring(response: 0.38, dampingFraction: 0.72).delay(Double(index) * 0.06),
            value: appeared
        )
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }
}
