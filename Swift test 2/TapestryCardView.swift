import SwiftUI

struct TapestryCardView: View {
    let tapestry:  Tapestry
    let thumbnail: UIImage?

    private static let accentPalette: [Color] = [
        Color(red: 0.95, green: 0.60, blue: 0.55),
        Color(red: 0.55, green: 0.75, blue: 0.95),
        Color(red: 0.75, green: 0.90, blue: 0.65),
        Color(red: 0.95, green: 0.80, blue: 0.50),
        Color(red: 0.80, green: 0.65, blue: 0.95),
        Color(red: 0.55, green: 0.90, blue: 0.85),
        Color(red: 0.95, green: 0.70, blue: 0.85),
    ]

    private var accent: Color {
        let hash = abs(tapestry.title.hashValue)
        return Self.accentPalette[hash % Self.accentPalette.count]
    }

    var body: some View {
        VStack(spacing: 8) {
            // Square cover
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [accent, accent.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "photo.artframe")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(width: 160, height: 160)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)

            // Title below
            Text(tapestry.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
        }
    }
}
