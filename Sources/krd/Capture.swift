import Foundation
import Accelerate
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import krdcore

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
    var format: krdcore.PixelFormat = .rgb
    /// Draw the pointer into the captured frame. Off by default: the mirrored cursor is redundant
    /// (the pane already follows the local pointer) and every mouse move would otherwise dirty the
    /// tiles under it. `--cursor` turns it on.
    var showsCursor = false

    private(set) var framesDelivered = 0
    private(set) var framesSkipped = 0
    private(set) var callbacks = 0
    private(set) var idleFrames = 0
    private(set) var badFrames = 0
    private var loggedBadFrame = false

    /// Called with (pixels, width, height) for every visually changed frame.
    var onFrame: (([UInt8], Int, Int) -> Void)?

    /// How old the frame already was when ScreenCaptureKit handed it over: `callback − PTS`, in ms.
    ///
    /// This is the half of the delay that used to be invisible. `pipe` (see `Desk.noteFrame`) starts
    /// at this callback, so a slow *capture* — the compositor waiting for a frame, a display waking
    /// up, a window being re-shot — was billed to our encoder. `-1` means "not measured": the mock
    /// and replay paths have no presentation timestamp, and the panel prints `—` rather than a
    /// confident zero (issue #52).
    public private(set) var lastCapMs = -1.0

    /// The stream died on its own (the window server dropped the connection, `-3805`, or the
    /// display was reconfigured under it). Without this the process keeps running, keeps writing
    /// stats, and leaves the last frame on screen forever -- a 30-minute soak found exactly that
    /// (issue #44): frozen at 10 min, `callbacks` never moving again, nothing in the log but one
    /// line. The owner decides whether to restart; this just reports.
    var onStreamStopped: ((Error) -> Void)?

    /// The configuration the running stream was started with (or last updated to). `SCStream` does
    /// not expose its own on this SDK, so this is the copy `updateSource` mutates.
    private var config: SCStreamConfiguration?

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
        self.config = config
    }

    /// Move the crop of the **running** stream, no teardown (`SCStream.updateConfiguration`).
    ///
    /// This is what `--zoom-follow` uses for a pan: stopping and starting the stream froze the
    /// picture for the length of a re-negotiation and was the main trigger of the stop/start path
    /// that hung in the #44 soak. Measured with `probe/zoom_update_probe.swift` on macOS 26.6: the
    /// new rect takes effect within one or two frames (p50 42 ms end to end), the stream keeps
    /// delivering, and nothing stops.
    ///
    enum Update: Equatable {
        case changed          // the stream was re-cropped, a frame is owed
        case unchanged        // same rect and size as the running stream: nothing to do, no frame owed
        case noStream         // nothing running; the caller falls back to a restart
    }

    /// Returns `.unchanged` when the request repeats the configuration the stream already has.
    ///
    /// That happens more than it sounds: `--zoom-follow` clamps the crop at the edge of the display,
    /// so a pointer parked in a corner asks for the same rect four times a second. Sending that to
    /// `updateConfiguration` is harmless but it produces **no frame** (nothing changed), and a
    /// caller that then waits for one is waiting for something that will never arrive -- which is
    /// exactly how the first version of this turned eight pans into eight needless restarts in a
    /// 6-minute soak.
    @discardableResult
    func updateSource(_ sourceRect: CGRect, width: Int, height: Int) async throws -> Update {
        guard let stream, var next = config else { return .noStream }
        if next.sourceRect == sourceRect, next.width == width, next.height == height {
            return .unchanged
        }
        next.sourceRect = sourceRect
        next.width = width
        next.height = height
        try await stream.updateConfiguration(next)
        config = next
        return .changed
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("capture stopped: \(error)\n")
        self.stream = nil
        onStreamStopped?(error)
    }

    /// Stop and forget the stream, but never wait for it indefinitely.
    ///
    /// `stopCapture()` on a stream that has *already* died (`-3805`) does not call back on macOS
    /// 26.6: the continuation is never resumed. `Desk.restartCapture` awaits this before it clears
    /// its "a restart is in flight" flag, so one hung stop wedges every later restart -- including
    /// the one that would repair the picture. Measured in the 30-minute soak (issue #44): the
    /// process stayed alive and idle, the main thread slept in its run loop, and nothing was ever
    /// logged again. Racing a timer is enough: the orphaned call is harmless.
    func stop(timeout: Double = 2.0) async {
        guard let stream else { return }
        self.stream = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await stream.stopCapture() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1e9)) }
            await group.next()
            group.cancelAll()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // Measured at the top, before the copy: this is "how long did the frame sit around before we
        // saw it", and everything after this line is `pipe`'s business. ScreenCaptureKit timestamps
        // in host time, which is the same base as `benchNowMs()` (uptime, no sleep).
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsSeconds = pts.isValid ? CMTimeGetSeconds(pts) : .nan
        if ptsSeconds.isFinite, ptsSeconds > 0 {
            let age = benchNowMs() - ptsSeconds * 1000
            lastCapMs = age.isFinite && age >= 0 && age < 60_000 ? age : -1
        } else {
            lastCapMs = -1
        }
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
