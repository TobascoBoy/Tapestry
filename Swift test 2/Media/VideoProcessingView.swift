import SwiftUI
import AVFoundation

struct VideoProcessingView: View {
    let videoURL: URL
    let onComplete: (VideoProcessor.Result) -> Void
    let onCancel:   () -> Void

    enum Stage {
        case choosing
        case processing(Float)
        case failed(String)
    }

    @State private var stage: Stage = .choosing
    @State private var thumbnail: UIImage?

    private var isProcessing: Bool {
        if case .processing = stage { true } else { false }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                // Thumbnail preview
                Group {
                    if let thumb = thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 220, height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(radius: 8)
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.quaternary)
                            .frame(width: 220, height: 220)
                            .overlay(
                                Image(systemName: "video.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .padding(.top, 16)

                switch stage {
                case .choosing:
                    choosingView
                case .processing(let prog):
                    processingView(prog)
                case .failed(let msg):
                    failedView(msg)
                }

                Spacer()
            }
            .navigationTitle("Add Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                        .disabled(isProcessing)
                }
            }
        }
        .task { await loadThumbnail() }
    }

    // MARK: - Stage views

    private var choosingView: some View {
        VStack(spacing: 14) {
            Text("Remove background?")
                .font(.headline)
            Text("Background removal uses Vision AI to cut out the subject frame by frame. Takes 15–30 seconds.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 10) {
                Button {
                    Task { await process(removeBackground: true) }
                } label: {
                    Label("Remove Background", systemImage: "person.and.background.dotted")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button {
                    Task { await process(removeBackground: false) }
                } label: {
                    Label("Keep Background", systemImage: "video.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.quaternary)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func processingView(_ prog: Float) -> some View {
        VStack(spacing: 16) {
            Text(prog < 0.89 ? "Removing background…" : prog < 0.95 ? "Encoding video…" : prog < 1.0 ? "Creating preview…" : "Done!")
                .font(.headline)
            Text("\(Int(prog * 100))%")
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            ProgressView(value: prog)
                .progressViewStyle(.linear)
                .padding(.horizontal, 32)
            Text("Please keep the app open")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func failedView(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Processing failed")
                .font(.headline)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") { stage = .choosing }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Logic

    private func loadThumbnail() async {
        let asset = AVURLAsset(url: videoURL)
        let gen   = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 440, height: 440)
        if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            thumbnail = UIImage(cgImage: cg)
        }
    }

    private func process(removeBackground: Bool) async {
        stage = .processing(0)
        let handleResult: (Swift.Result<VideoProcessor.Result, Error>) -> Void = { result in
            switch result {
            case .success(let r): onComplete(r)
            case .failure(let e): stage = .failed(e.localizedDescription)
            }
        }
        if removeBackground {
            VideoProcessor.removeBackground(
                inputURL: videoURL,
                progress: { p in stage = .processing(p) },
                completion: handleResult
            )
        } else {
            VideoProcessor.copy(inputURL: videoURL, completion: handleResult)
        }
    }
}
