import SwiftUI

// MARK: - Tapestry Card (Bubble)

struct TapestryCardView: View {
    let tapestry:  Tapestry
    let thumbnail: UIImage?

    @State private var isFloating = false

    // Compute hash once — used by all three derived properties below
    private var titleHash: Int { abs(tapestry.title.hashValue) }

    private static let accentPalette: [Color] = [
        Color(red: 0.95, green: 0.60, blue: 0.55),
        Color(red: 0.55, green: 0.75, blue: 0.95),
        Color(red: 0.75, green: 0.90, blue: 0.65),
        Color(red: 0.95, green: 0.80, blue: 0.50),
        Color(red: 0.80, green: 0.65, blue: 0.95),
        Color(red: 0.55, green: 0.90, blue: 0.85),
        Color(red: 0.95, green: 0.70, blue: 0.85),
    ]
    private static let iridescentBase: [Color] = [
        Color(red: 0.85, green: 0.50, blue: 1.00),
        Color(red: 0.40, green: 0.75, blue: 1.00),
        Color(red: 0.45, green: 1.00, blue: 0.80),
        Color(red: 0.90, green: 1.00, blue: 0.45),
        Color(red: 1.00, green: 0.72, blue: 0.30),
        Color(red: 1.00, green: 0.38, blue: 0.62),
        Color(red: 0.85, green: 0.50, blue: 1.00),
    ]

    private var accentColor:      Color  { Self.accentPalette[titleHash % Self.accentPalette.count] }
    private var floatDuration:    Double { 1.9 + Double(titleHash % 6) * 0.12 }
    private var iridescentColors: [Color] {
        let shift = titleHash % 7
        // Rotate the pre-allocated static array without any heap allocation
        return Self.iridescentBase.dropFirst(shift) + Self.iridescentBase.prefix(shift) + [Self.iridescentBase[shift]]
    }

    var body: some View {
        // Compute once — used for accent, float duration, and iridescent colours
        let hash     = titleHash
        let accent   = Self.accentPalette[hash % Self.accentPalette.count]
        let duration = 1.9 + Double(hash % 6) * 0.12
        let shift    = hash % 7
        let iridescent: [Color] = Array(Self.iridescentBase.dropFirst(shift))
                                + Array(Self.iridescentBase.prefix(shift))
                                + [Self.iridescentBase[shift]]

        ZStack {
            // ── Content ──────────────────────────────────────────────────────
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 180, height: 180)
                } else {
                    LinearGradient(
                        colors: [accent, accent.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: 180, height: 180)
                    .overlay {
                        Image(systemName: "photo.artframe")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .mask {
                RadialGradient(
                    stops: [
                        .init(color: .black, location: 0.00),
                        .init(color: .black, location: 0.72),
                        .init(color: .clear,  location: 1.00),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 90
                )
            }

            // ── Bubble rim layers ─────────────────────────────────────────────

            // 1. Outer accent glow
            Circle()
                .stroke(accent.opacity(0.25), lineWidth: 22)
                .blur(radius: 14)

            // 2. Iridescent refraction band
            Circle()
                .strokeBorder(
                    AngularGradient(colors: iridescent, center: .center),
                    lineWidth: 4
                )
                .opacity(0.55)
                .blendMode(.screen)

            // 3. Edge darkening
            Circle()
                .strokeBorder(
                    RadialGradient(
                        colors: [.clear, .black.opacity(0.22)],
                        center: .center,
                        startRadius: 72,
                        endRadius: 90
                    ),
                    lineWidth: 18
                )

            // 4. Top-left specular
            Circle()
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.80), location: 0.00),
                            .init(color: .white.opacity(0.30), location: 0.12),
                            .init(color: .clear,               location: 0.30),
                            .init(color: .clear,               location: 1.00),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
        }
        .frame(width: 180, height: 180)
        // Rasterise blur + screen-blend compositing into a single Metal texture,
        // avoiding per-frame offscreen-render passes while scrolling / floating.
        .drawingGroup()
        .shadow(color: accent.opacity(0.40), radius: 40, x: 0, y: 20)
        .shadow(color: accent.opacity(0.22), radius: 18, x: 0, y: 6)
        .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
        .offset(y: isFloating ? -4 : 4)
        .onAppear {
            withAnimation(
                .easeInOut(duration: duration)
                .repeatForever(autoreverses: true)
            ) {
                isFloating = true
            }
        }
    }
}
