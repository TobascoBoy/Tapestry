import AVFoundation
import Vision
import UIKit

// MARK: - VideoProcessor

final class VideoProcessor {

    struct Result {
        let outputURL:  URL
        let thumbnail:  UIImage
        let duration:   Double
        let bgRemoved:  Bool
    }

    // MARK: - Public API

    static func copy(
        inputURL:   URL,
        completion: @escaping @MainActor (Swift.Result<Result, Error>) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            do    { await completion(.success(try await copyVideo(inputURL: inputURL))) }
            catch { await completion(.failure(error)) }
        }
    }

    static func removeBackground(
        inputURL:   URL,
        progress:   @escaping (Float) -> Void,
        completion: @escaping @MainActor (Swift.Result<Result, Error>) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            do    { await completion(.success(try await removeBg(inputURL: inputURL, progress: progress))) }
            catch { await completion(.failure(error)) }
        }
    }

    // MARK: - Copy (no processing)

    private static func copyVideo(inputURL: URL) async throws -> Result {
        let asset   = AVURLAsset(url: inputURL)
        let dur     = try await asset.load(.duration)
        let capSecs = min(CMTimeGetSeconds(dur), 15.0)
        let outURL  = tmpURL("mov")

        guard let session = AVAssetExportSession(asset: asset,
                                                  presetName: AVAssetExportPresetHighestQuality)
        else { throw Err("Export session failed") }
        session.outputURL      = outURL
        session.outputFileType = .mov
        session.timeRange      = CMTimeRange(start: .zero,
                                             duration: CMTime(seconds: capSecs, preferredTimescale: 600))
        await session.export()
        if let e = session.error { throw e }
        return Result(outputURL: outURL, thumbnail: makeThumbnail(outURL, masked: false), duration: capSecs, bgRemoved: false)
    }

    // MARK: - Background removal

    private static func removeBg(
        inputURL: URL,
        progress: @escaping (Float) -> Void
    ) async throws -> Result {

        let asset   = AVURLAsset(url: inputURL)
        let dur     = try await asset.load(.duration)
        let capSecs = min(CMTimeGetSeconds(dur), 10.0)

        guard let track = try await asset.loadTracks(withMediaType: .video).first
        else { throw Err("No video track") }

        let fps        = Double(try await track.load(.nominalFrameRate))
        let writeFPS   = min(max(fps, 1.0), 15.0) // 15 fps keeps encoding fast
        let frameCount = Int(capSecs * writeFPS)
        let frameDur   = 1.0 / writeFPS

        // AVAssetImageGenerator handles orientation automatically
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform   = true
        gen.requestedTimeToleranceBefore     = CMTime(seconds: frameDur / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter      = CMTime(seconds: frameDur / 2, preferredTimescale: 600)

        guard let firstFrame = try? gen.copyCGImage(at: .zero, actualTime: nil)
        else { throw Err("Could not read first frame") }

        // Output size — max 720px, even dimensions for HEVC
        let scale  = min(720.0 / CGFloat(max(firstFrame.width, firstFrame.height)), 1.0)
        let outW   = Int(floor(CGFloat(firstFrame.width)  * scale / 2) * 2)
        let outH   = Int(floor(CGFloat(firstFrame.height) * scale / 2) * 2)
        let outSize = CGSize(width: outW, height: outH)

        let outURL = tmpURL("mov")
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)

        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey:  AVVideoCodecType.hevcWithAlpha.rawValue,
                AVVideoWidthKey:  outW,
                AVVideoHeightKey: outH,
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.8]
            ]
        )
        writerInput.expectsMediaDataInRealTime = false

        // Pixel buffer pool — BGRA with alpha preserved
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey           as String: outW,
                kCVPixelBufferHeightKey          as String: outH
            ]
        )
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Signal immediately so the UI never shows 0% while detection runs.
        await MainActor.run { progress(0.01) }

        // Detect person in first frame to choose the right segmentation path.
        let personDetect = VNDetectHumanRectanglesRequest()
        let detectHandler = VNImageRequestHandler(cgImage: firstFrame, options: [:])
        try? detectHandler.perform([personDetect])
        let hasPerson = personDetect.results?.contains { $0.confidence > 0.5 } ?? false

        // Person path uses the pre-warmed VNGeneratePersonSegmentationRequest (better edges).
        // Falls back to VNGenerateForegroundInstanceMaskRequest if not warmed up or not a person.
        let personReq: VNGeneratePersonSegmentationRequest? = {
            // Use static isWarmedUp — never triggers lazy init, never blocks this thread.
            guard hasPerson, PersonSegmentationWarmup.isWarmedUp else { return nil }
            let r = VNGeneratePersonSegmentationRequest()
            r.qualityLevel = .balanced
            r.outputPixelFormat = kCVPixelFormatType_OneComponent8
            return r
        }()
        let visionReq = VNGenerateForegroundInstanceMaskRequest()
        let progressInterval = max(1, frameCount / 100)

        for i in 0..<frameCount {
            let time = CMTime(seconds: Double(i) * frameDur, preferredTimescale: 600)
            guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { continue }

            // Per-frame: try person segmentation, fall back to foreground mask if it returns nil.
            let buf: CVPixelBuffer
            if let personReq, let personBuf = personMaskedPixelBuffer(from: cg, outSize: outSize, request: personReq) {
                buf = personBuf
            } else {
                buf = maskedPixelBuffer(from: cg, outSize: outSize, request: visionReq)
            }

            while !writerInput.isReadyForMoreMediaData { await Task.yield() }
            adaptor.append(buf, withPresentationTime: time)

            if i % progressInterval == 0 || i == frameCount - 1 {
                // Cap at 0.88 — the remaining 12% is reserved for HEVC encoding + thumbnail
                let p = Float(i + 1) / Float(frameCount) * 0.88
                await MainActor.run { progress(p) }
                try? await Task.sleep(nanoseconds: 16_700_000)
            }
        }

        await MainActor.run { progress(0.90) }
        writerInput.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        if writer.status == .failed { throw writer.error ?? Err("Writer failed") }

        await MainActor.run { progress(0.97) }
        let thumbnail = makeThumbnail(outURL, masked: true)
        await MainActor.run { progress(1.0) }
        return Result(outputURL: outURL, thumbnail: thumbnail, duration: capSecs, bgRemoved: true)
    }

    // MARK: - Core: Vision mask → BGRA pixel buffer with real alpha

    /// Person segmentation path — CGContext clip approach avoids CIImage pipeline issues.
    /// Returns nil on failure so the caller can fall back to maskedPixelBuffer.
    private static func personMaskedPixelBuffer(
        from cgImage: CGImage,
        outSize: CGSize,
        request: VNGeneratePersonSegmentationRequest
    ) -> CVPixelBuffer? {
        let outW = Int(outSize.width)
        let outH = Int(outSize.height)

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first
        else { return nil }

        let maskBuffer = observation.pixelBuffer
        let maskW = CVPixelBufferGetWidth(maskBuffer)
        let maskH = CVPixelBufferGetHeight(maskBuffer)

        // Convert the grayscale mask pixel buffer → CGImage
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }

        guard let maskCtx = CGContext(
            data:             CVPixelBufferGetBaseAddress(maskBuffer),
            width:            maskW,
            height:           maskH,
            bitsPerComponent: 8,
            bytesPerRow:      CVPixelBufferGetBytesPerRow(maskBuffer),
            space:            CGColorSpaceCreateDeviceGray(),
            bitmapInfo:       CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        ), let maskCGImage = maskCtx.makeImage() else { return nil }

        // Create output buffer (zeroed = fully transparent)
        let out = clearBuffer(width: outW, height: outH)
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }

        guard let ctx = CGContext(
            data:             CVPixelBufferGetBaseAddress(out),
            width:            outW,
            height:           outH,
            bitsPerComponent: 8,
            bytesPerRow:      CVPixelBufferGetBytesPerRow(out),
            space:            CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:       CGImageAlphaInfo.premultipliedFirst.rawValue |
                              CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)

        // Clip to person mask — pixels outside the mask remain transparent (zero alpha).
        // Both the mask and source CGImage are drawn in CGContext's y-up space, so they
        // are flipped consistently and align correctly with each other.
        ctx.clip(to: outRect, mask: maskCGImage)
        ctx.draw(cgImage, in: outRect)
        return out
    }

    private static func maskedPixelBuffer(
        from cgImage: CGImage,
        outSize: CGSize,
        request: VNGenerateForegroundInstanceMaskRequest
    ) -> CVPixelBuffer {

        let outW = Int(outSize.width)
        let outH = Int(outSize.height)

        // Run Vision on the original CGImage
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first,
              !obs.allInstances.isEmpty
        else {
            return clearBuffer(width: outW, height: outH)
        }

        // generateMaskedImage returns a CVPixelBuffer where non-subject pixels are transparent
        guard let masked = try? obs.generateMaskedImage(
            ofInstances: obs.allInstances,
            from: handler,
            croppedToInstancesExtent: false
        ) else {
            return clearBuffer(width: outW, height: outH)
        }

        // The masked buffer may be any size — blit it into a correctly-sized BGRA buffer
        // that preserves alpha. We use CGContext with premultipliedFirst (BGRA on iOS).
        return blitToBGRA(source: masked, outW: outW, outH: outH)
    }

    private static func blitToBGRA(source: CVPixelBuffer, outW: Int, outH: Int) -> CVPixelBuffer {
        let srcW = CVPixelBufferGetWidth(source)
        let srcH = CVPixelBufferGetHeight(source)

        // Create output buffer
        let out = clearBuffer(width: outW, height: outH)
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }

        // Create CGContext over the output buffer — premultipliedFirst + little-endian = BGRA
        guard let ctx = CGContext(
            data:             CVPixelBufferGetBaseAddress(out),
            width:            outW,
            height:           outH,
            bitsPerComponent: 8,
            bytesPerRow:      CVPixelBufferGetBytesPerRow(out),
            space:            CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:       CGImageAlphaInfo.premultipliedFirst.rawValue |
                              CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return out }

        // Convert the Vision output buffer to a CGImage and draw scaled into ctx
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let srcCtx = CGContext(
            data:             CVPixelBufferGetBaseAddress(source),
            width:            srcW,
            height:           srcH,
            bitsPerComponent: 8,
            bytesPerRow:      CVPixelBufferGetBytesPerRow(source),
            space:            CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:       CGImageAlphaInfo.premultipliedFirst.rawValue |
                              CGBitmapInfo.byteOrder32Little.rawValue
        ), let srcImage = srcCtx.makeImage() else { return out }

        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return out
    }

    private static func clearBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pb
        )
        guard let pb else { fatalError("CVPixelBufferCreate failed") }
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb), 0,
               CVPixelBufferGetHeight(pb) * CVPixelBufferGetBytesPerRow(pb))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    // MARK: - Thumbnail

    private static func makeThumbnail(_ url: URL, masked: Bool) -> UIImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return UIImage() }
        guard masked else { return UIImage(cgImage: cg) }

        // Apply Vision mask to thumbnail so the still preview has transparent bg
        let req     = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        guard (try? handler.perform([req])) != nil,
              let obs = req.results?.first,
              !obs.allInstances.isEmpty,
              let maskedBuf = try? obs.generateMaskedImage(ofInstances: obs.allInstances,
                                                            from: handler,
                                                            croppedToInstancesExtent: false)
        else { return UIImage(cgImage: cg) }

        let w = CVPixelBufferGetWidth(maskedBuf)
        let h = CVPixelBufferGetHeight(maskedBuf)
        let outBuf = blitToBGRA(source: maskedBuf, outW: w, outH: h)

        // Render to CGImage preserving alpha
        CVPixelBufferLockBaseAddress(outBuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(outBuf, .readOnly) }
        guard let outCtx = CGContext(
            data:             CVPixelBufferGetBaseAddress(outBuf),
            width:            w, height: h,
            bitsPerComponent: 8,
            bytesPerRow:      CVPixelBufferGetBytesPerRow(outBuf),
            space:            CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:       CGImageAlphaInfo.premultipliedFirst.rawValue |
                              CGBitmapInfo.byteOrder32Little.rawValue
        ), let outCG = outCtx.makeImage() else { return UIImage(cgImage: cg) }

        return UIImage(cgImage: outCG)
    }

    // MARK: - Helpers

    private static func tmpURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    private static func Err(_ msg: String) -> NSError {
        NSError(domain: "VideoProcessor", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
