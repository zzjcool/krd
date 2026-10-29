import Foundation
import Accelerate
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// ScreenCaptureKit wrapper: one stream, one callback queue, BGRA -> RGBA with vImage.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "krd.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var rgba = [UInt8]()
    private var previous: [UInt8]?

    private(set) var framesDelivered = 0
    private(set) var framesSkipped = 0
    private(set) var callbacks = 0
    private(set) var idleFrames = 0
    private(set) var badFrames = 0

    /// Called with (pixels, width, height) for every visually changed frame.
    var onFrame: (([UInt8], Int, Int) -> Void)?

    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int) async throws {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3   // queueDepth 1 stalls the stream on this macOS build
        config.showsCursor = true
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
        // Idle/blank frames (screen unchanged) carry no pixels at all, and the status
        // attachment may be missing entirely -- going by the pixel buffer is the only
        // reliable test. Note `as? Int` on the attachment silently fails; it is NSNumber.
        let status = (CMGetAttachment(sampleBuffer,
                                      key: SCStreamFrameInfo.status.rawValue as CFString,
                                      attachmentModeOut: nil) as? NSNumber)?.intValue ?? 0
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if status == 0 { badFrames += 1 } else { idleFrames += 1 }
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let needed = w * h * 4
        if rgba.count != needed { rgba = [UInt8](repeating: 0, count: needed) }

        var src = vImage_Buffer(
            data: base,
            height: vImagePixelCount(h),
            width: vImagePixelCount(w),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        // ScreenCaptureKit hands us BGRA; the protocol wants RGBA. One SIMD pass.
        let permute: [UInt8] = [2, 1, 0, 3]
        rgba.withUnsafeMutableBytes { dst in
            var out = vImage_Buffer(
                data: dst.baseAddress,
                height: vImagePixelCount(h),
                width: vImagePixelCount(w),
                rowBytes: w * 4
            )
            vImagePermuteChannels_ARGB8888(&src, &out, permute, vImage_Flags(kvImageNoFlags))
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
}
