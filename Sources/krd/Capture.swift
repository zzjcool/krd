import Foundation
import Accelerate
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// ScreenCaptureKit wrapper: one stream, one callback queue, BGRA -> RGBA with vImage.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "krd.capture", qos: .userInteractive)
    private var stream: SCStream?
    /// Frame buffer, in the wire format (3 bytes/px for RGB, 4 for RGBA).
    private var rgba = [UInt8]()
    /// Second buffer. Reusing one buffer every frame means the mutation below has to copy the
    /// whole frame first (the previous frame still references it); alternating two buffers keeps
    /// each one uniquely referenced when it is written. See issue #1.
    private var spare = [UInt8]()
    private var previous: [UInt8]?
    /// Matches ScreenWriter.format; set before start().
    var format: PixelFormat = .rgb
    /// Draw the pointer into the captured frame. Off means the picture shows a bare desktop:
    /// the mirrored cursor is redundant (the pane already follows the local pointer) and every
    /// mouse move would otherwise dirty the tiles under it.
    var showsCursor = true

    private(set) var framesDelivered = 0
    private(set) var framesSkipped = 0
    private(set) var callbacks = 0
    private(set) var idleFrames = 0
    private(set) var badFrames = 0
    private var loggedBadFrame = false

    /// Called with (pixels, width, height) for every visually changed frame.
    var onFrame: (([UInt8], Int, Int) -> Void)?

    /// `sourceRect` crops on the server (macOS 14+), so a zoomed capture copies *fewer* pixels per
    /// frame instead of being upscaled on the CPU. It is relative to the filter's content origin
    /// (see `Desk.cropForFilter`).
    func start(filter: SCContentFilter, sourceRect: CGRect?, width: Int, height: Int, fps: Int) async throws {
        let config = SCStreamConfiguration()
        if let sourceRect, sourceRect.width >= 1, sourceRect.height >= 1 {
            config.sourceRect = sourceRect
        }
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3   // queueDepth 1 stalls the stream on this macOS build
        config.showsCursor = showsCursor
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("capture stopped: \(error)\n")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        callbacks += 1
        // The frame's state lives in the buffer's *sample attachments*, not in `CMGetAttachment`:
        // that call has never returned anything here, so `?? 0` silently turned every frame into
        // "complete" and every idle frame into a bad one (issue #25).
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                           as? [[String: Any]])?.first
        let status = (attachments?[SCStreamFrameInfo.status.rawValue] as? NSNumber)?.intValue

        // Three states, kept apart. A frame with no pixels is only *broken* when it claims to be
        // complete (or when the buffer itself is unusable); a screen that simply did not change
        // arrives as `.idle` — or, on some builds, with no status at all — and belongs in `idle`.
        guard CMSampleBufferIsValid(sampleBuffer) else {
            badFrames += 1
            logBadFrame(status: status, attachments: attachments)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if status == SCFrameStatus.complete.rawValue {
                badFrames += 1
                logBadFrame(status: status, attachments: attachments)
            } else {
                idleFrames += 1
            }
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            // A frame that claims to be complete but cannot be read is the other genuine error.
            badFrames += 1
            logBadFrame(status: status, attachments: attachments)
            return
        }

        let bpp = format.bytesPerPixel
        let needed = w * h * bpp
        if rgba.count != needed {
            rgba = [UInt8](repeating: 0, count: needed)
            spare = [UInt8](repeating: 0, count: needed)
        } else if previous != nil {
            swap(&rgba, &spare)         // never write into the buffer `previous` is holding
        }

        var src = vImage_Buffer(
            data: base,
            height: vImagePixelCount(h),
            width: vImagePixelCount(w),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        // ScreenCaptureKit hands us BGRA. The desktop is opaque, so RGB is enough: one SIMD pass
        // that drops the alpha byte and rotates the channels (issue #4). RGBA keeps the old path.
        rgba.withUnsafeMutableBytes { dst in
            var out = vImage_Buffer(
                data: dst.baseAddress,
                height: vImagePixelCount(h),
                width: vImagePixelCount(w),
                rowBytes: w * bpp
            )
            if format == .rgb {
                vImageConvert_BGRA8888toRGB888(&src, &out, vImage_Flags(kvImageNoFlags))
            } else {
                let permute: [UInt8] = [2, 1, 0, 3]
                vImagePermuteChannels_ARGB8888(&src, &out, permute, vImage_Flags(kvImageNoFlags))
            }
        }

        // A static desktop costs zero bandwidth: skip byte-identical frames.
        if let prev = previous, prev == rgba {
            framesSkipped += 1
            return
        }
        previous = rgba
        framesDelivered += 1
        onFrame?(rgba, w, h)
    }

    /// One line the first time a bad frame shows up: what that frame actually carried. `bad` is
    /// supposed to be rare, so the next report of it should not need a rebuild to say more than
    /// "it climbs" (issue #25).
    private func logBadFrame(status: Int?, attachments: [String: Any]?) {
        guard !loggedBadFrame else { return }
        loggedBadFrame = true
        let keys = attachments.map { $0.keys.sorted().joined(separator: " ") } ?? "none"
        Log.write("capture: first bad frame after \(callbacks) callbacks — status="
                  + (status.map(String.init) ?? "missing")
                  + " (0=complete 1=idle 2=blank 3=suspended 4=started 5=stopped)"
                  + "\n         attachments: \(keys)\n")
    }
}
