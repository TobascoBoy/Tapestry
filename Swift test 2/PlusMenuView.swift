import SwiftUI

// MARK: - Plus Dropdown Menu

struct PlusDropdownMenu: View {
    let onSelect: (PlusMenuItem) -> Void

    private let items: [PlusMenuItem] = [.photo, .video, .text, .background, .music]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Button { onSelect(item) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(item.color)
                            .frame(width: 22)
                        Text(item.label)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    Divider().padding(.leading, 50)
                }
            }
        }
        .frame(width: 165)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .transition(.scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity))
    }
}

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

// MARK: - PlusMenuOverlay (Text / Background / Music only)

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
                menuRow(.video,      index: 1)
                menuRow(.text,       index: 2)
                menuRow(.background, index: 3)
                menuRow(.music,      index: 4)
            }
            .padding(.top, 52)
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

// MARK: - Bubble Plus Button (tapestry-style, self-contained pulse animation)

struct BubblePlusButton: View {
    let showPlusMenu: Bool
    let showMediaDropdown: Bool
    let onTap: () -> Void

    @State private var pulse = false
    @State private var size: CGFloat = 44

    private let rimColors: [Color] = [
        Color(red: 0.85, green: 0.50, blue: 1.00),
        Color(red: 0.40, green: 0.75, blue: 1.00),
        Color(red: 0.45, green: 1.00, blue: 0.80),
        Color(red: 0.90, green: 1.00, blue: 0.45),
        Color(red: 1.00, green: 0.38, blue: 0.62),
        Color(red: 0.85, green: 0.50, blue: 1.00),
    ]

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: size, height: size)
                // Blurred rainbow glow rim
                .overlay {
                    if showPlusMenu {
                        Circle()
                            .stroke(AngularGradient(colors: rimColors, center: .center), lineWidth: 9)
                            .blur(radius: 5)
                            .opacity(pulse ? 0.75 : 0.30)
                            .animation(.easeInOut(duration: 1.4), value: pulse)
                    }
                }
                // Sharp rainbow rim + gloss
                .overlay {
                    if showPlusMenu {
                        Circle()
                            .stroke(AngularGradient(colors: rimColors, center: .center), lineWidth: 2)
                        Circle()
                            .stroke(
                                LinearGradient(stops: [
                                    .init(color: .white.opacity(0.75), location: 0.00),
                                    .init(color: .white.opacity(0.15), location: 0.16),
                                    .init(color: .clear,               location: 0.36),
                                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1
                            )
                    }
                }
                // Icon
                .overlay {
                    Image(systemName: showPlusMenu ? "camera.fill" : "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .offset(y: showPlusMenu ? (pulse ? -2 : 2) : 0)
                        .animation(.easeInOut(duration: 1.4), value: pulse)
                }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 1.4), value: pulse)
        .onChange(of: showPlusMenu) { _, isOpen in
            pulse = false
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
                size = isOpen ? 56 : 44
            }
            if isOpen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            }
        }
    }
}

// MARK: - Media shoot-left row (Photo + Video spring out horizontally)

struct MediaShootRow: View {
    let onSelect: (PlusMenuItem) -> Void

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 10) {

            // Video — secondary: compact circle, springs in second
            Button { onSelect(.video) } label: {
                ZStack {
                    Circle()
                        .fill(PlusMenuItem.video.color)
                        .frame(width: 44, height: 44)
                    Image(systemName: PlusMenuItem.video.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                // Shadow on the ZStack composite, not on the inner Circle.
                // Putting shadow inside a ZStack renders the blurred disc as a
                // separate layer between the circle and the icon, making it look
                // like a second button behind the first (the "underlay" effect).
                .shadow(color: PlusMenuItem.video.color.opacity(0.45), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : 60)
            .animation(
                .spring(response: 0.38, dampingFraction: 0.58).delay(0.07),
                value: appeared
            )

            // Photo — primary CTA: pill shape with label.
            // A capsule is unambiguously different from the circular BubblePlusButton
            // that floats in the nav bar at the same height, so there is no longer any
            // risk of the two circles being read as one button sitting on another.
            Button { onSelect(.photo) } label: {
                HStack(spacing: 7) {
                    Image(systemName: PlusMenuItem.photo.icon)
                        .font(.system(size: 15, weight: .bold))
                    Text("Add Photo")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Capsule().fill(PlusMenuItem.photo.color))
                .shadow(color: PlusMenuItem.photo.color.opacity(0.50), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : 60)
            .animation(
                .spring(response: 0.38, dampingFraction: 0.58),
                value: appeared
            )
        }
        .onAppear {
            withAnimation { appeared = true }
        }
    }
}

