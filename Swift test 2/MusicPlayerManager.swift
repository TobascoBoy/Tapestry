import AVFoundation
import Combine
import UIKit

// MARK: - MusicPlayerManager
//
// Singleton AVPlayer wrapper. Only one track plays at a time —
// tapping play on a new card stops the previous one automatically.
// Music sticker cards observe `currentlyPlayingID` to update their UI.

@MainActor
final class MusicPlayerManager: ObservableObject {
    static let shared = MusicPlayerManager()

    @Published private(set) var currentlyPlayingID: UUID? = nil
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0     // 0–1
    @Published private(set) var duration: Double = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var itemObserver: AnyCancellable?

    private init() {
        // Allow audio to play over silent mode switch
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Public API

    func play(stickerID: UUID, url: URL) {
        // If this card is already playing, pause it
        if currentlyPlayingID == stickerID && isPlaying {
            pause()
            return
        }

        // Stop whatever was playing before
        stop()

        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)

        // Observe duration once item is ready
        itemObserver = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                if status == .readyToPlay {
                    self?.duration = item.asset.duration.seconds
                }
            }

        // Time observer for progress bar
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, let dur = self.player?.currentItem?.duration.seconds, dur > 0 else { return }
            self.progress = time.seconds / dur
        }

        // Auto-stop at end
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        player?.play()
        currentlyPlayingID = stickerID
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        player?.pause()
        player = nil
        itemObserver = nil
        currentlyPlayingID = nil
        isPlaying = false
        progress = 0
        duration = 0
    }

    @objc private func playerDidFinish() {
        stop()
    }
}
