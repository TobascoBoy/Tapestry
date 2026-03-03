import Foundation
import UIKit

// MARK: - MusicTrack
// Value type representing a song from the iTunes Search API.
// Holds everything the music sticker card needs to display and play.

struct MusicTrack: Identifiable {
    let id: String          // iTunes trackId as String
    let title: String
    let artistName: String
    let artworkURL: URL?
    let previewURL: URL?    // 30-second MP3 preview — free, no account needed

    // Resolved artwork image — filled in after async fetch
    var artworkImage: UIImage?
}
