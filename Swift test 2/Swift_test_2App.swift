import SwiftUI

@main
struct Swift_test_2App: App {
    @State private var auth          = AuthManager()
    @State private var tapestryStore = TapestryStore()

    @AppStorage("app_appearance") private var appAppearance: Int = 0  // 0=system, 1=light, 2=dark

    private var preferredColorScheme: ColorScheme? {
        switch appAppearance {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isLoading {
                    Color(.systemBackground).ignoresSafeArea()
                } else if auth.isSignedIn {
                    ContentView()
                        .environment(tapestryStore)
                        .environment(auth)
                } else {
                    AuthView()
                        .environment(auth)
                }
            }
            .preferredColorScheme(preferredColorScheme)
            .onAppear {
                // Run in parallel — NatureSegmenter loads a large CoreML model and
                // must not block PersonSegmentationWarmup from starting.
                DispatchQueue.global(qos: .utility).async { _ = NatureSegmentationProcessor.shared }
                DispatchQueue.global(qos: .utility).async { _ = PersonSegmentationWarmup.shared }
            }
            .onChange(of: auth.isSignedIn) { _, signedIn in
                if signedIn {
                    tapestryStore.currentUserID = auth.userID
                    Task { await tapestryStore.fetch() }
                } else {
                    tapestryStore.currentUserID = nil
                    tapestryStore.clear()
                }
            }
        }
    }
}
