import AVFoundation
import Vision
import UIKit
import CoreImage

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
        progress:   @escaping @MainActor (Float) -> Void,
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
        progress: @escaping @MainActor (Float) -> Void
    ) async throws -> Result {

        let asset   = AVURLAsset(url: inputURL)
        let dur     = try await asset.load(.duration)
        let capSecs = min(CMTimeGetSeconds(dur), 15.0)

        guard let track = try await asset.loadTracks(withMediaType: .video).first
        else { throw Err("No video track") }

        let fps        = Double(try await track.load(.nominalFrameRate))
        let writeFPS   = min(max(fps, 1.0), 30.0)
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

        let visionReq = VNGenerateForegroundInstanceMaskRequest()

        for i in 0..<frameCount {
            let time = CMTime(seconds: Double(i) * frameDur, preferredTimescale: 600)
            guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { continue }

            let buf = maskedPixelBuffer(from: cg, outSize: outSize, request: visionReq)
            while !writerInput.isReadyForMoreMediaData { await Task.yield() }
            adaptor.append(buf, withPresentationTime: time)

            await progress(Float(i + 1) / Float(frameCount))
        }

        writerInput.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        if writer.status == .failed { throw writer.error ?? Err("Writer failed") }

        await progress(1.0)
        return Result(outputURL: outURL, thumbnail: makeThumbnail(outURL, masked: true), duration: capSecs, bgRemoved: true)
    }

    // MARK: - Core: Vision mask → BGRA pixel buffer with real alpha

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

    static func makeThumbnail(_ url: URL, masked: Bool) -> UIImage {
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
