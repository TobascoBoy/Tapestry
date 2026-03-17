import SwiftUI
import AVFoundation

private struct SplashView: View {
    @State private var opacity: Double = 0

    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .overlay(
                Text("TAPESTRY")
                    .font(.custom("Avenir-Light", size: 24))
                    .tracking(3)
                    .foregroundStyle(.primary)
                    .opacity(opacity)
            )
            .onAppear {
                withAnimation(.easeIn(duration: 0.8)) {
                    opacity = 1
                }
            }
    }
}

@main
struct Swift_test_2App: App {
    @State private var auth             = AuthManager()
    @State private var tapestryStore    = TapestryStore()
    @State private var splashMinimumDone = false   // enforces minimum logo display time

    @AppStorage("app_appearance") private var appAppearance: Int = 0  // 0=system, 1=light, 2=dark

    private var preferredColorScheme: ColorScheme? {
        switch appAppearance {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    private var showingSplash: Bool { auth.isLoading || !splashMinimumDone }

    var body: some Scene {
        WindowGroup {
            Group {
                if showingSplash {
                    SplashView()
                } else if auth.isSignedIn {
                    ContentView()
                        .environment(tapestryStore)
                        .environment(auth)
                        .transition(.opacity)
                } else {
                    AuthView()
                        .environment(auth)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: showingSplash)
            .animation(.easeInOut(duration: 0.4), value: auth.isSignedIn)
            .preferredColorScheme(preferredColorScheme)
            .onAppear {
                // Default session: playback + mixWithOthers so muted video stickers
                // (AVQueuePlayer) never interrupt music when a tapestry loads.
                // MusicPlayerManager.play() overrides this to exclusive .playback
                // when the user explicitly taps a music sticker.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])

                // Run in parallel — NatureSegmenter loads a large CoreML model and
                // must not block PersonSegmentationWarmup from starting.
                DispatchQueue.global(qos: .utility).async { _ = NatureSegmentationProcessor.shared }
                DispatchQueue.global(qos: .utility).async { _ = PersonSegmentationWarmup.shared }

                // Keep the splash up for at least 2.5 seconds so the logo has real screen time
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    splashMinimumDone = true
                }
            }
            .onChange(of: auth.isSignedIn) { _, signedIn in
                if signedIn {
                    tapestryStore.currentUserID = auth.userID
                    Task { await tapestryStore.fetch() }
                    if let uid = auth.userID {
                        Task { await ProfileService.fetchAndCache(userID: uid) }
                    }
                } else {
                    tapestryStore.currentUserID = nil
                    tapestryStore.clear()
                }
            }
        }
    }
}
