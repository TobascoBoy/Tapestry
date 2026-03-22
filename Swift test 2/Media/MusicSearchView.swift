import SwiftUI

// MARK: - iTunes Search API models

private struct ITunesResponse: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable, Identifiable {
    let trackId: Int
    let trackName: String
    let artistName: String
    let artworkUrl100: String?
    let previewUrl: String?

    var id: Int { trackId }
}

// MARK: - MusicSearchView
//
// Uses the free iTunes Search API — no Apple Developer account,
// no entitlements, no Info.plist changes needed.
// 30-second preview MP3s are included in every result for free.

struct MusicSearchView: View {
    let onSelect: (MusicTrack) -> Void
    let onCancel: () -> Void

    @State private var query       = ""
    @State private var results:    [ITunesTrack] = []
    @State private var isSearching = false
    @State private var errorMessage: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search songs, artists…", text: $query)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { triggerSearch() }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            results = []
                            errorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Body
                if isSearching {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if let err = errorMessage {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    Spacer()
                } else if results.isEmpty && !query.isEmpty {
                    Spacer()
                    ContentUnavailableView.search(text: query)
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Search for a song to add to your canvas")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    Spacer()
                } else {
                    List(results) { track in
                        Button { selectTrack(track) } label: {
                            TrackRow(track: track)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
            .onChange(of: query) { _, newValue in
                // Debounce: wait 400ms after last keystroke before searching
                searchTask?.cancel()
                guard !newValue.trimmingCharacters(in: .whitespaces).isEmpty else {
                    results = []; return
                }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    await search(term: newValue)
                }
            }
        }
    }

    // MARK: - Search

    private func triggerSearch() {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searchTask = Task { await search(term: query) }
    }

    private func search(term: String) async {
        await MainActor.run {
            isSearching = true
            errorMessage = nil
        }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term",   value: term),
            URLQueryItem(name: "media",  value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit",  value: "30"),
        ]

        do {
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            let decoded = try JSONDecoder().decode(ITunesResponse.self, from: data)
            await MainActor.run {
                results = decoded.results
                isSearching = false
            }
        } catch {
            await MainActor.run {
                isSearching = false
                if !Task.isCancelled {
                    errorMessage = "Search failed — check your connection"
                }
            }
        }
    }

    // MARK: - Selection

    private func selectTrack(_ track: ITunesTrack) {
        let artURL  = track.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100", with: "300x300")) }
        let prevURL = track.previewUrl.flatMap { URL(string: $0) }
 
        let musicTrack = MusicTrack(
            id: String(track.trackId),
            title: track.trackName,
            artistName: track.artistName,
            artworkURL: artURL,
            previewURL: prevURL
        )
        onSelect(musicTrack)
    }
}

// MARK: - Track row

private struct TrackRow: View {
    let track: ITunesTrack

    var body: some View {
        HStack(spacing: 12) {
            // Artwork
            AsyncImage(url: track.artworkUrl100.flatMap { URL(string: $0) }) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Text
            VStack(alignment: .leading, spacing: 3) {
                Text(track.trackName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Preview indicator
            if track.previewUrl != nil {
                Image(systemName: "play.circle")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
