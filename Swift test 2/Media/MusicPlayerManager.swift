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
    private var finishObserver: NSObjectProtocol?
    private var itemObserver: AnyCancellable?

    // Dedicated background queue for the periodic time observer.
    // AVFoundation requires removeTimeObserver to be called on the same queue
    // it was registered on. Using a background (non-main) queue means removal
    // never blocks or deadlocks the main thread.
    private let observerQueue = DispatchQueue(label: "com.tapestry.music.timeobserver", qos: .userInteractive)

    private init() {}

    // MARK: - Public API

    func play(stickerID: UUID, url: URL) {
        if currentlyPlayingID == stickerID && isPlaying {
            pause()
            return
        }

        stop()

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer

        // Observe status for duration
        itemObserver = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak newPlayer] status in
                guard status == .readyToPlay else { return }
                Task { @MainActor [weak self, weak newPlayer] in
                    guard let asset = newPlayer?.currentItem?.asset,
                          let dur = try? await asset.load(.duration) else { return }
                    let secs = dur.seconds
                    if secs.isFinite && secs > 0 { self?.duration = secs }
                }
            }

        // Register time observer on a background queue to avoid deadlocking
        // when removeTimeObserver is called from the main thread via @MainActor
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: observerQueue) { [weak self, weak newPlayer] time in
            guard let dur = newPlayer?.currentItem?.duration.seconds,
                  dur.isFinite && dur > 0 else { return }
            let prog = time.seconds / dur
            DispatchQueue.main.async { [weak self, weak newPlayer] in
                guard let self, self.player === newPlayer else { return }
                self.progress = prog
            }
        }

        // Block-based observer — token-based removal never crashes,
        // unlike the old selector-based removeObserver(self:) which could crash
        // when called from a Swift @MainActor Task context
        finishObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }

        newPlayer.play()
        currentlyPlayingID = stickerID
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        player?.play()
        isPlaying = true
    }

    func stop() {
        itemObserver = nil
        // Remove time observer on the same background queue it was registered on.
        // Async dispatch means this never blocks the main thread.
        // The player is captured strongly so it lives until removeTimeObserver finishes.
        if let token = timeObserver, let p = player {
            let capturedPlayer = p
            let capturedToken = token
            timeObserver = nil
            observerQueue.async {
                capturedPlayer.removeTimeObserver(capturedToken)
            }
        }

        if let obs = finishObserver {
            NotificationCenter.default.removeObserver(obs)
            finishObserver = nil
        }

        player?.pause()
        player = nil
        currentlyPlayingID = nil
        isPlaying = false
        progress = 0
        duration = 0

        // Restore mixing so muted video stickers activating the session
        // afterward don't interrupt other audio (external or in-app).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
