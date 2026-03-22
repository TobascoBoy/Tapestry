import SwiftUI
import AVFoundation

// MARK: - SplashView

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

// MARK: - AppDelegate

private class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .portrait
    }
}

// MARK: - AppTab

enum AppTab { case profile, discover }

// MARK: - RootContentView

private struct RootContentView: View {
    let auth: AuthManager
    let store: TapestryStore

    @State private var selectedTab: AppTab = .profile

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Tab content ─────────────────────────────────────────────────
            ProfileView()
                .environment(store)
                .environment(auth)
                .opacity(selectedTab == .profile ? 1 : 0)
                .allowsHitTesting(selectedTab == .profile)

            NavigationStack {
                SearchView()
                    .toolbar(.hidden, for: .navigationBar)
            }
            .environment(auth)
            .environment(store)
            .opacity(selectedTab == .discover ? 1 : 0)
            .allowsHitTesting(selectedTab == .discover)

            // ── Custom tab bar ───────────────────────────────────────────────
            AppTabBar(selectedTab: $selectedTab)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - AppTabBar

private struct AppTabBar: View {
    @Binding var selectedTab: AppTab

    // Spotify uses a near-black solid bar regardless of system theme.
    private let barBackground = Color(red: 0.08, green: 0.08, blue: 0.08)
    private let activeColor   = Color.white
    private let inactiveColor = Color(white: 0.50)

    var body: some View {
        VStack(spacing: 0) {
            // Subtle gradient shadow bleeding upward — Spotify-style depth
            LinearGradient(
                colors: [barBackground.opacity(0), barBackground],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 20)
            .allowsHitTesting(false)

            HStack(spacing: 0) {
                tabButton(tab: .profile,
                          icon: "person",
                          filledIcon: "person.fill",
                          label: "Profile")
                tabButton(tab: .discover,
                          icon: "magnifyingglass",
                          filledIcon: "sparkle.magnifyingglass",
                          label: "Discover")
            }
            .padding(.top, 8)
            .safeAreaPadding(.bottom)
            .background(barBackground)
        }
    }

    private func tabButton(tab: AppTab, icon: String, filledIcon: String, label: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: selectedTab == tab ? filledIcon : icon)
                    .font(.system(size: 24, weight: selectedTab == tab ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tab ? activeColor : inactiveColor)
                    .scaleEffect(selectedTab == tab ? 1.05 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: selectedTab)

                Text(label)
                    .font(.system(size: 10, weight: selectedTab == tab ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tab ? activeColor : inactiveColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Swift_test_2App

@main
struct Swift_test_2App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var auth             = AuthManager()
    @State private var tapestryStore    = TapestryStore()
    @State private var splashMinimumDone = false   // enforces minimum logo display time
    @State private var showOnboarding   = false
    @State private var showOnboardingCreate = false  // cascade to CreateTapestryView after onboarding

    @AppStorage("app_appearance") private var appAppearance: Int = 0  // 0=system, 1=light, 2=dark

    // Per-user onboarding flag so returning users on the same device are never shown it again
    private func onboardingKey(for uid: UUID) -> String { "onboarding_complete_\(uid)" }
    private func hasCompletedOnboarding(for uid: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: onboardingKey(for: uid))
    }
    private func markOnboardingComplete(for uid: UUID) {
        UserDefaults.standard.set(true, forKey: onboardingKey(for: uid))
    }

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
                    RootContentView(auth: auth, store: tapestryStore)
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
            .onOpenURL { url in
                Task { await auth.handle(url: url) }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(
                    onSkip: {
                        if let uid = auth.userID { markOnboardingComplete(for: uid) }
                        showOnboarding = false
                    },
                    onCreateTapestry: {
                        if let uid = auth.userID { markOnboardingComplete(for: uid) }
                        showOnboarding = false
                        // Small delay so the cover dismisses before the next sheet appears
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            showOnboardingCreate = true
                        }
                    }
                )
                .environment(auth)
            }
            .sheet(isPresented: $showOnboardingCreate) {
                CreateTapestryView()
                    .environment(tapestryStore)
            }
            .onChange(of: auth.isSignedIn) { _, signedIn in
                if signedIn {
                    tapestryStore.currentUserID = auth.userID
                    Task { await tapestryStore.fetch() }
                    if let uid = auth.userID {
                        Task { await ProfileService.fetchAndCache(userID: uid) }
                        // Backfill display_name / bio / pronouns to Supabase from local cache.
                        // This ensures the users table is populated for search even if the
                        // user has never explicitly saved their profile through settings.
                        let cachedName     = UserDefaults.standard.string(forKey: "profile_name")     ?? ""
                        let cachedBio      = UserDefaults.standard.string(forKey: "profile_bio")      ?? ""
                        let cachedPronouns = UserDefaults.standard.string(forKey: "profile_pronouns") ?? ""
                        if !cachedName.isEmpty {
                            ProfileService.saveText(userID: uid, name: cachedName,
                                                    bio: cachedBio, pronouns: cachedPronouns)
                        }
                        if !hasCompletedOnboarding(for: uid) {
                            showOnboarding = true
                        }
                    }
                } else {
                    tapestryStore.currentUserID = nil
                    tapestryStore.clear()
                    // Clear cached profiele so the next account's sign-in starts blank
                    for key in ["profile_name", "profile_bio", "profile_pronouns",
                                "profile_avatar_url", "profile_has_photo"] {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                    // Remove local avatar file
                    try? FileManager.default.removeItem(at: ProfileService.localAvatarURL())
                }
            }
        }
    }
}
