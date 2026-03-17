#if DEBUG
import SwiftUI
import AVFoundation
import Vision

// MARK: - VideoDebugView
// Add this temporarily to ContentView to test the pipeline step by step.
// Replace ContentView with: VideoDebugView()

struct VideoDebugView: View {
    @State private var log: [String] = []
    @State private var outputImage: UIImage? = nil
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let img = outputImage {
                        Text("✅ Output frame:").bold()
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .border(Color.green, width: 2)
                    }

                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("❌") ? .red :
                                             line.hasPrefix("✅") ? .green : .primary)
                    }
                }
                .padding()
            }
            .navigationTitle("Video Debug")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isRunning ? "Running…" : "Run Test") {
                        Task { await runTest() }
                    }
                    .disabled(isRunning)
                }
            }
        }
    }

    private func addLog(_ s: String) {
        log.append(s)
        print(s)
    }

    private func runTest() async {
        isRunning = true
        log = []
        outputImage = nil

        // ── Step 1: Find a video in the photo library ─────────────────────
        addLog("Step 1: Looking for a video file to test with…")

        // We'll use a bundled test by creating a simple synthetic pixel buffer
        // to test Vision in isolation first
        addLog("Step 2: Creating synthetic test frame (solid color)…")
        guard let testBuffer = makeSyntheticBuffer(width: 640, height: 480, color: (100, 150, 200)) else {
            addLog("❌ Failed to create test buffer"); isRunning = false; return
        }
        addLog("✅ Test buffer created: \(CVPixelBufferGetWidth(testBuffer))×\(CVPixelBufferGetHeight(testBuffer))")
        addLog("   Format: \(CVPixelBufferGetPixelFormatType(testBuffer))")

        // ── Step 3: Run Vision on the synthetic frame ─────────────────────
        addLog("Step 3: Running VNGenerateForegroundInstanceMaskRequest on synthetic frame…")
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: testBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([req])
            let count = req.results?.count ?? 0
            addLog("✅ Vision ran successfully. Results count: \(count)")
            if count == 0 {
                addLog("   (Expected — synthetic solid color has no subject)")
            }
        } catch {
            addLog("❌ Vision failed on synthetic frame: \(error)")
        }

        // ── Step 4: Pick a real video URL from tmp if one exists ──────────
        let tmp = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) {
            let vids = files.filter { $0.hasSuffix(".mov") || $0.hasSuffix(".mp4") }
            addLog("Step 4: Found \(vids.count) video file(s) in tmp: \(vids)")

            if let first = vids.first {
                let url = tmp.appendingPathComponent(first)
                await testVideoFile(url: url)
            } else {
                addLog("⚠️ No video files in tmp yet — add a video sticker first, then re-run")
            }
        }

        isRunning = false
    }

    private func testVideoFile(url: URL) async {
        addLog("Step 5: Testing video at: \(url.lastPathComponent)")

        let asset = AVURLAsset(url: url)

        // Check tracks
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            addLog("❌ No video track in file"); return
        }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let transform   = (try? await track.load(.preferredTransform)) ?? .identity
        let fps         = (try? await track.load(.nominalFrameRate)) ?? 0
        let dur         = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        addLog("✅ Track found: naturalSize=\(naturalSize), fps=\(fps), dur=\(String(format: "%.1f", dur))s")
        addLog("   Transform: a=\(transform.a) b=\(transform.b) c=\(transform.c) d=\(transform.d)")

        let tSize = naturalSize.applying(transform)
        addLog("   Display size: \(abs(tSize.width))×\(abs(tSize.height))")

        // Try reading one frame
        addLog("Step 6: Reading first frame…")
        guard let reader = try? AVAssetReader(asset: asset) else {
            addLog("❌ Could not create AVAssetReader"); return
        }

        let dispW = abs(tSize.width)
        let dispH = abs(tSize.height)
        let scale = min(720 / max(dispW, dispH), 1.0)
        let outW  = floor(dispW * scale / 2) * 2
        let outH  = floor(dispH * scale / 2) * 2
        addLog("   Work size: \(outW)×\(outH) (scale=\(String(format: "%.3f", scale)))")

        let comp = AVMutableVideoComposition()
        comp.renderSize    = CGSize(width: outW, height: outH)
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: min(dur, 15), preferredTimescale: 600))
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        li.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instr.layerInstructions = [li]
        comp.instructions = [instr]

        let out = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        out.videoComposition = comp
        out.alwaysCopiesSampleData = false
        reader.add(out)

        guard reader.startReading() else {
            addLog("❌ Reader failed to start: \(reader.error?.localizedDescription ?? "unknown")")
            return
        }
        addLog("✅ Reader started")

        guard let sample = out.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sample) else {
            addLog("❌ Could not read first sample buffer. Reader status: \(reader.status.rawValue)")
            if reader.status == .failed { addLog("   Error: \(reader.error?.localizedDescription ?? "nil")") }
            return
        }
        addLog("✅ First frame read: \(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb))")

        // Capture for display
        let ciImg = CIImage(cvPixelBuffer: pb)
        let ctx   = CIContext()
        if let cg = ctx.createCGImage(ciImg, from: ciImg.extent) {
            await MainActor.run { outputImage = UIImage(cgImage: cg) }
            addLog("✅ Frame displayed above")
        }

        // Run Vision
        addLog("Step 7: Running Vision on real frame…")
        let req2 = VNGenerateForegroundInstanceMaskRequest()
        let h2   = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do {
            try h2.perform([req2])
            let results = req2.results ?? []
            addLog("✅ Vision ran. Results: \(results.count)")
            for (i, r) in results.enumerated() {
                addLog("   Result[\(i)]: instances=\(r.allInstances)")
            }
            if results.isEmpty {
                addLog("⚠️ No subjects detected in first frame")
                addLog("   This means bg removal would produce transparent frames")
                addLog("   Check: is there a clear subject in the video?")
            } else {
                // Try generating the mask
                addLog("Step 8: Generating masked image…")
                do {
                    let masked = try results[0].generateMaskedImage(
                        ofInstances: results[0].allInstances,
                        from: h2,
                        croppedToInstancesExtent: false
                    )
                    let ci2 = CIImage(cvPixelBuffer: masked)
                    if let cg2 = ctx.createCGImage(ci2, from: ci2.extent) {
                        await MainActor.run { outputImage = UIImage(cgImage: cg2) }
                        addLog("✅ Masked frame displayed above — bg removal WORKS")
                    }
                } catch {
                    addLog("❌ generateMaskedImage failed: \(error)")
                }
            }
        } catch {
            addLog("❌ Vision failed on real frame: \(error)")
        }

        reader.cancelReading()
    }

    private func makeSyntheticBuffer(width: Int, height: Int, color: (UInt8, UInt8, UInt8)) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let ptr  = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr  = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bpr + x * 4
                ptr[i]   = color.2  // B
                ptr[i+1] = color.1  // G
                ptr[i+2] = color.0  // R
                ptr[i+3] = 255      // A
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
#endif
