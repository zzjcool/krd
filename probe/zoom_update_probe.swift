// Can a running SCStream change its `sourceRect` in place?
//
// Issue #54: `--zoom-follow` pans the crop by stopping and starting the whole stream, which
// freezes the picture during the teardown and is the main trigger of the stop/start path that hung
// in the #44 soak. ScreenCaptureKit has `updateConfiguration(_:)` for exactly this, but whether it
// actually re-crops a *running* stream -- promptly, repeatedly, and without dropping the stream --
// is the question this probe answers. Nothing in krd changes until it says yes.
//
//     swift probe/zoom_update_probe.swift            # on the machine being mirrored
//
// It starts a 1280x720 stream over the full display, then pans the source rect 10 times in a row,
// printing for each pan: latency to the first frame after the update, the frame size, whether the
// pixels actually changed, and how many frames arrived before the next pan. A crop that scales up
// a sub-region must look different from the full screen, so a `diff` near zero means the update was
// ignored (the number printed is the mean absolute difference over a sampled grid, 0-255).
//
// Exit code 0 = reliable, 1 = not. macOS 26.6 / kraal-agent is what it was written against.

import AppKit
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

let OUTPUT_W = 1280
let OUTPUT_H = 720
let BASE_SECONDS = 2.0
let PANS = 10
let PAN_GAP = 1.0

func now() -> Double { Date().timeIntervalSince1970 }

final class Collector: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Frame {
        var t: Double
        var w: Int
        var h: Int
        var sample: [UInt8]      // RGBA grid, 8x8
    }

    private let lock = NSLock()
    private(set) var frames: [Frame] = []
    private(set) var stops: [String] = []
    let queue = DispatchQueue(label: "probe.capture", qos: .userInteractive)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var sample = [UInt8]()
        sample.reserveCapacity(8 * 8 * 4)
        // An 8x8 grid of pixels: enough to tell "a different part of the screen" from "the same".
        for gy in 0..<8 {
            for gx in 0..<8 {
                let x = max(0, min(w - 1, gx * w / 8 + w / 16))
                let y = max(0, min(h - 1, gy * h / 8 + h / 16))
                let offset = y * stride + x * 4
                sample.append(contentsOf: [base.load(fromByteOffset: offset, as: UInt8.self),
                                           base.load(fromByteOffset: offset + 1, as: UInt8.self),
                                           base.load(fromByteOffset: offset + 2, as: UInt8.self),
                                           base.load(fromByteOffset: offset + 3, as: UInt8.self)])
            }
        }
        lock.lock()
        frames.append(Frame(t: now(), w: w, h: h, sample: sample))
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        stops.append("\(error)")
        lock.unlock()
        print("probe: STREAM STOPPED: \(error)")
    }

    func snapshot() -> (frames: [Frame], stops: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, stops)
    }

    /// First frame strictly after `t`, waiting up to `timeout`.
    func frame(after t: Double, timeout: Double = 2.0) -> Frame? {
        let deadline = now() + timeout
        while now() < deadline {
            if let frame = snapshot().frames.first(where: { $0.t > t }) { return frame }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }
}

func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard !a.isEmpty, a.count == b.count else { return -1 }
    var total = 0
    for (x, y) in zip(a, b) { total += abs(Int(x) - Int(y)) }
    return Double(total) / Double(a.count)
}

func dumpSample(_ sample: [UInt8]) -> String {
    // Four pixels in hex, so a human can see that the frame really is a different region.
    let pixels = stride(from: 0, to: min(sample.count, 16), by: 4).map { index in
        String(format: "%02x%02x%02x", sample[index], sample[index + 1], sample[index + 2])
    }
    return pixels.joined(separator: " ")
}

// krd has the same note in main.swift: ScreenCaptureKit only behaves on this macOS build when an
// AppKit application context exists.
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

guard let display = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?
    .displays.first else {
    print("probe: no displays (screen recording permission?)")
    exit(2)
}
let width = display.width
let height = display.height
print("probe: display \(display.displayID) \(width)x\(height)")

let collector = Collector()
let config = SCStreamConfiguration()
config.width = OUTPUT_W
config.height = OUTPUT_H
config.pixelFormat = kCVPixelFormatType_32BGRA
config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
config.queueDepth = 3
// Hidden by default, exactly like krd after #51: a visible cursor would be a content change of its
// own, and the question is whether the *update* pushes a frame.
let showCursor = ProcessInfo.processInfo.environment["KRD_PROBE_CURSOR"] != nil
config.showsCursor = showCursor
config.colorSpaceName = CGColorSpace.sRGB
config.sourceRect = CGRect(x: 0, y: 0, width: width, height: height)

let filter = SCContentFilter(display: display, excludingWindows: [])
let stream = SCStream(filter: filter, configuration: config, delegate: collector)
do {
    try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: collector.queue)
    try await stream.startCapture()
} catch {
    print("probe: could not start the stream: \(error)")
    exit(2)
}
print("probe: stream started, output \(OUTPUT_W)x\(OUTPUT_H), sourceRect \(width)x\(height) at 0,0")

Thread.sleep(forTimeInterval: BASE_SECONDS)
let base = collector.snapshot()
guard !base.frames.isEmpty else {
    print("probe: no frames in \(BASE_SECONDS)s -- nothing to measure")
    exit(2)
}
let frameRate = Double(base.frames.count) / BASE_SECONDS
let sizes = Set(base.frames.map { "\($0.w)x\($0.h)" })
print(String(format: "probe: frames=%d in %.2fs (%.1f/s), sizes=%@",
             base.frames.count, BASE_SECONDS, frameRate, sizes.sorted().joined(separator: ",")))
print("probe: baseline pixel sample: \(dumpSample(base.frames.last!.sample))")

/// Frames in the next `seconds`, and a count of how many arrived while the picture was still.
func window(_ seconds: Double) -> (count: Int, start: Double) {
    let start = now()
    Thread.sleep(forTimeInterval: seconds)
    return (collector.snapshot().frames.filter { $0.t > start }.count, start)
}

/// Move the pointer inside `region` (so the move is *inside the crop*, which is what the stream
/// can see) and count the frames that arrive. `KRD_PROBE_JIGGLE=0` turns the pointer off, which is
/// the interesting case: then nothing changes except the crop the update asked for.
func jiggle(inside region: CGRect, seconds: Double) -> Int {
    guard ProcessInfo.processInfo.environment["KRD_PROBE_JIGGLE"] != "0" else { return -1 }
    let start = now()
    let deadline = start + seconds
    var index = 0
    while now() < deadline {
        let stepX: Double = 0.6 * Double(index % 3) / 2.0
        let stepY: Double = 0.6 * Double((index / 3) % 3) / 2.0
        let fx: Double = 0.2 + stepX
        let fy: Double = 0.2 + stepY
        let px: CGFloat = region.minX + region.width * CGFloat(fx)
        let py: CGFloat = region.minY + region.height * CGFloat(fy)
        let point = CGPoint(x: px, y: py)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                mouseButton: .left)?.post(tap: .cghidEventTap)
        index += 1
        Thread.sleep(forTimeInterval: 0.05)
    }
    return collector.snapshot().frames.filter { $0.t > start }.count
}

/// The frame that arrives first after an update can still be the old crop (it was already in flight
/// when the configuration changed), so "settled" means a later frame that differs from what we had.
func settle(after requested: Double, from previous: Collector.Frame)
    -> (frame: Collector.Frame, attempts: Int, diff: Double)? {
    guard var frame = collector.frame(after: requested) else { return nil }
    var attempts = 1
    var diff = meanDiff(previous.sample, frame.sample)
    while diff <= 3.0, attempts < 4 {
        guard let next = collector.frame(after: frame.t, timeout: 0.4) else { break }
        frame = next
        attempts += 1
        diff = meanDiff(previous.sample, frame.sample)
    }
    return (frame, attempts, diff)
}

let fullScreen = CGRect(x: 0, y: 0, width: width, height: height)
let controlIdle: Int = window(1.0).count
let controlMoving: Int = jiggle(inside: fullScreen, seconds: 1.0)
let controlLine: String = "probe: control (no update yet): idle 1000 ms -> \(controlIdle) frames"
let controlLine2: String = "; pointer inside the whole screen -> \(controlMoving) frames"
print(controlLine + controlLine2)

// Pan through regions that look different from each other and from the full screen. A crop that is
// honoured scales up, so both the pixels and (usually) the shape of the content change.
var regions: [CGRect] = [
    CGRect(x: 0, y: 0, width: width / 3, height: height / 3),
    CGRect(x: width - width / 3, y: height - height / 3, width: width / 3, height: height / 3),
    CGRect(x: width / 2 - width / 6, y: height / 2 - height / 6, width: width / 3, height: height / 3),
    CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2),
]
// Every pan narrows; panning back out to the whole screen is the restore step below, so that the
// restore always has something to compare against (a no-op update cannot be told from a broken one).

// `SCStream.configuration` is not exposed in this SDK, so keep our own copy: the same way
// `Capturer` will have to do it.
var live = config
var previous = base.frames.last!
var failures = 0
var latencies: [Double] = []
var panned = 0

for step in 0..<PANS {
    let region = regions[step % regions.count]
    var next = live
    next.sourceRect = region
    next.width = OUTPUT_W
    next.height = OUTPUT_H
    let requested = now()
    do {
        try await stream.updateConfiguration(next)
        live = next
    } catch {
        print("probe: update \(step + 1) FAILED: \(error)")
        failures += 1
        break
    }
    guard let result = settle(after: requested, from: previous) else {
        print(String(format: "probe: update %d at %dx%d+%d+%d -> NO FRAME within 2 s",
                     step + 1, Int(region.width), Int(region.height),
                     Int(region.minX), Int(region.minY)))
        failures += 1
        break
    }
    let settled = result.frame
    let changed = result.diff > 3.0
    if changed { panned += 1 } else { failures += 1 }
    latencies.append((settled.t - requested) * 1000)
    let firstNote = result.attempts > 1 ? " (first frame was stale)" : ""
    print(String(format: "probe: update %2d rect %4dx%-4d at %4d,%-4d -> %d frame(s) to settle, "
                 + "total %5.1f ms, size %dx%d, diff %5.1f (%@)%@, sample %@",
                 step + 1, Int(region.width), Int(region.height), Int(region.minX), Int(region.minY),
                 result.attempts, (settled.t - requested) * 1000, settled.w, settled.h, result.diff,
                 changed ? "changed" : "UNCHANGED", firstNote, dumpSample(settled.sample)))
    previous = settled
    // Two separate questions, and the second one decides everything: does the stream keep
    // delivering *idle* frames after an update (the watchdog's liveness signal), and -- far more
    // important -- does it still deliver frames when the content *changes* (the only thing the
    // mirror needs)? A pointer move is a guaranteed visible change (`showsCursor` is on).
    let idleFrames: Int = window(PAN_GAP).count
    let moved: Int = jiggle(inside: region, seconds: PAN_GAP)
    if moved == 0 { failures += 1 }
    let blind: String = moved == 0 ? "  <-- BLIND" : (moved < 0 ? "  (pointer off)" : "")
    let idleMs: Int = Int(PAN_GAP * 1000)
    print("probe:    idle \(idleMs) ms -> \(idleFrames) frames; pointer inside the crop -> \(moved) frames\(blind)")
}

// Restore the full screen and make sure that works too: a stream that can only be narrowed would
// still be unusable for `--zoom-follow`, which pans in both directions.
var restore = live
restore.sourceRect = CGRect(x: 0, y: 0, width: width, height: height)
let restoreAt = now()
do {
    try await stream.updateConfiguration(restore)
    live = restore
    if let result = settle(after: restoreAt, from: previous) {
        let ok = result.diff > 3.0
        latencies.append((result.frame.t - restoreAt) * 1000)
        if !ok { failures += 1 }
        print(String(format: "probe: restore full screen -> %d frame(s) to settle, total %5.1f ms, "
                     + "size %dx%d, diff %5.1f (%@)", result.attempts,
                     (result.frame.t - restoreAt) * 1000, result.frame.w, result.frame.h,
                     result.diff, ok ? "changed" : "UNCHANGED"))
    } else {
        failures += 1
        print("probe: restore -> no frame within 2 s")
    }
} catch {
    failures += 1
    print("probe: restore FAILED: \(error)")
}

try? await stream.stopCapture()

let final = collector.snapshot()
var biggestGap = 0.0
for (a, b) in zip(final.frames, final.frames.dropFirst()) {
    biggestGap = max(biggestGap, b.t - a.t)
}
let sorted = latencies.sorted()
let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
let worst = sorted.last ?? 0
// `biggestGap` is deliberately *not* part of this: on this VM ScreenCaptureKit sends nothing while
// the content is static (control phase above: 0 frames in 1 s), so a long gap during the pans says
// "the screen did not change", not "the stream is broken". Liveness is checked per pan instead, by
// moving the pointer inside the crop and requiring frames.
let reliable = failures == 0 && panned == PANS && final.stops.isEmpty

print()
print(String(format: "probe: %d/%d pans changed the picture, %d failures, %d stream stops, "
             + "latency p50 %.1f ms / max %.1f ms, biggest frame gap %.0f ms, %d frames total",
             panned, PANS, failures, final.stops.count, p50, worst, biggestGap * 1000,
             final.frames.count))
print("probe: reliable here means: every update settles on the new rect within a frame or two, "
      + "the stream keeps delivering change frames, and nothing stops")
print("probe: verdict: \(reliable ? "RELIABLE" : "NOT RELIABLE")")
exit(reliable ? 0 : 1)
