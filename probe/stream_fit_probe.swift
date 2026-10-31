// Does an SCStream scale its source up to the requested size, or draw the source at its own size
// in the top-left of a bigger canvas and pad the rest with black?  `SCStreamConfiguration.scalesToFit`
// decides, its default is `false`, and that default is wrong for `desktopIndependentWindow:` filters
// (a small window is padded) while it happens to look right for display filters (the display is
// usually as big as the request anyway).  This probe re-measures that on any machine; nothing in krd
// changes based on what it says.
//
//     swiftc -O probe/stream_fit_probe.swift -o /tmp/stream-fit
//     /tmp/stream-fit window <windowID> <w> <h> [--fit|--no-fit]
//     /tmp/stream-fit display <displayID> <w> <h> [--fit|--no-fit]
//
// `krd --list` (or `.build/release/krd --list`) prints the ids.  An omitted flag means `--no-fit`,
// which is ScreenCaptureKit's own default.  Needs Screen Recording permission.
//
// It prints one line on stderr, unbuffered (stdout is lost when `timeout` kills the process):
//
//     <kind> <id> native <x>px asked <w>x<h> scalesToFit=<flag> -> frame <W>x<H>; non-bg bbox ...
//
// The frame's bottom-right pixel is taken as the background colour (the padding colour -- black in
// practice) and the bbox is the extent of everything that differs from it, as an absolute size and
// as a percentage of the frame.  How to read it:
//
//   * bbox ~= the requested size                  => the source was SCALED to the canvas; `--fit`
//                                                    is doing its job.
//   * bbox ~= the source's native pixels, anchored
//     to the top-left, big empty right/bottom      => PADDING: the source was blitted 1:1 into a
//     margin                                          larger canvas.  This is the bug that
//                                                    `scalesToFit` exists to fix, and it is what a
//                                                    window filter does by default.
//
// "Anchored to the top-left" is tested loosely on purpose: a window's own rounded-corner/shadow
// inset means x0/y0 is a few pixels in, not 0 (the Notification Center widget below starts at 16).
// So the tests are `x0, y0 <= 10% of the frame` and `right/bottom edge <= 90% of the frame`, plus
// `bbox <= 1.25x the source's native px`.  The trailing `=> SCALED / PADDED / INCONCLUSIVE` on the
// output line is that rule applied; the numbers around it are there so you can disagree with it.
//
// The percentages are canvas-relative (share of the frame, `bw * 100 / frameW`): a window that is not filled edge to
// edge by its own pixels reports slightly under 100% (a 360x180 pt widget at 2x in a 1440x720
// request shows 48% x 46% padded, 96% x 92% scaled), which is expected -- only the origin and the
// native-px comparison tell padding and scaling apart.
//
// A display capture cannot show the difference at all: the desktop fills the canvas whether it was
// scaled or not, so a full-display stream prints 100% x 100% for `--fit` and `--no-fit` alike.  The
// bbox only tells the two apart when the source is smaller than the request, which is exactly the
// window-filter case.
//
// One caveat learned the hard way: `NSScreen.main?.backingScaleFactor` is touched before any
// `SCContentFilter` is built.  A bare script (no NSApplication, no window) that goes straight to
// ScreenCaptureKit traps on a `CGS_REQUIRE_INIT` assertion otherwise.

import Foundation
import CoreGraphics
import ScreenCaptureKit
import CoreVideo

func emit(_ m: String) { FileHandle.standardError.write(Data((m + "\n").utf8)) }

func usage(_ why: String) -> Never {
    emit("stream-fit: \(why)")
    emit("usage: stream-fit window <windowID> <w> <h> [--fit|--no-fit]")
    emit("       stream-fit display <displayID> <w> <h> [--fit|--no-fit]")
    exit(2)
}

let argv = CommandLine.arguments
guard argv.count >= 5 else { usage("expected at least 4 arguments") }

let kind = argv[1]
guard kind == "window" || kind == "display" else { usage("unknown mode \"\(kind)\"") }
guard let wantedID = UInt32(argv[2]) else { usage("\"\(argv[2])\" is not a numeric id") }
guard let wantW = Int(argv[3]), let wantH = Int(argv[4]), wantW > 0, wantH > 0 else {
    usage("wanted size must be two positive integers")
}

var useFit = false
switch argv.count > 5 ? argv[5] : "--no-fit" {
case "--fit", "fit": useFit = true
case "--no-fit", "no-fit": useFit = false
default: usage("unknown flag \"\(argv[5])\"")
}

/// Where the non-background pixels are, and how many there are.
struct Content {
    let frameW: Int, frameH: Int
    let x0: Int, y0: Int, bw: Int, bh: Int, pixels: Int
    var right: Int { x0 + bw }
    var bottom: Int { y0 + bh }
    var pcW: Double { 100.0 * Double(bw) / Double(max(frameW, 1)) }
    var pcH: Double { 100.0 * Double(bh) / Double(max(frameH, 1)) }
    var describe: String {
        String(format: "frame %dx%d; non-bg bbox x0=%d y0=%d %dx%d (%.0f%% x %.0f%%), %d px",
               frameW, frameH, x0, y0, bw, bh, pcW, pcH, pixels)
    }
}

func measure(_ buf: CVPixelBuffer) -> Content? {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    guard CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA else { return nil }
    let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
    let stride = CVPixelBufferGetBytesPerRow(buf)
    guard w > 1, h > 1, let base = CVPixelBufferGetBaseAddress(buf) else { return nil }

    // The bottom-right pixel is the cheapest background sample that is always padding in a
    // top-left-anchored, padded frame.
    let corner = base.advanced(by: (h - 1) * stride + (w - 1) * 4).assumingMemoryBound(to: UInt8.self)
    let bgB = Int(corner[0]), bgG = Int(corner[1]), bgR = Int(corner[2])

    var x0 = w, y0 = h, x1 = -1, y1 = -1, n = 0
    for y in 0..<h {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            let q = row.advanced(by: x * 4)
            let d = abs(Int(q[0]) - bgB) + abs(Int(q[1]) - bgG) + abs(Int(q[2]) - bgR)
            guard d > 24 else { continue }
            n += 1
            if x < x0 { x0 = x }
            if y < y0 { y0 = y }
            if x > x1 { x1 = x }
            if y > y1 { y1 = y }
        }
    }
    guard x1 >= 0 else { return Content(frameW: w, frameH: h, x0: 0, y0: 0, bw: 0, bh: 0, pixels: 0) }
    return Content(frameW: w, frameH: h, x0: x0, y0: y0,
                   bw: x1 + 1 - x0, bh: y1 + 1 - y0, pixels: n)
}

/// Scaled vs padded, per the rules in the header.  `native` is the source's own pixel size.
func verdict(_ c: Content, native: (w: Int, h: Int)?) -> String {
    let fw = Double(c.frameW), fh = Double(c.frameH)
    if Double(c.bw) >= 0.90 * fw && Double(c.bh) >= 0.90 * fh {
        return "SCALED -- content fills the request"
    }
    let anchoredTopLeft = Double(c.x0) <= 0.10 * fw && Double(c.y0) <= 0.10 * fh
    let leavesMargin = Double(c.right) <= 0.90 * fw || Double(c.bottom) <= 0.90 * fh
    if let n = native, anchoredTopLeft, leavesMargin,
       Double(c.bw) <= 1.25 * Double(n.w), Double(c.bh) <= 1.25 * Double(n.h) {
        return "PADDED -- ~native \(n.w)x\(n.h) anchored top-left, request not filled"
    }
    return "INCONCLUSIVE -- bbox is neither the request nor the native size"
}

final class Grabber: NSObject, SCStreamOutput {
    var frame: CVPixelBuffer?
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, frame == nil,
              let buf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frame = buf
    }
}

func firstFrame(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CVPixelBuffer? {
    let grabber = Grabber()
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try stream.addStreamOutput(grabber, type: .screen, sampleHandlerQueue: .global())
    try await stream.startCapture()
    let deadline = Date().addingTimeInterval(5)
    while grabber.frame == nil && Date() < deadline { usleep(50_000) }
    try? await stream.stopCapture()
    return grabber.frame
}

func configuration(fit: Bool) -> SCStreamConfiguration {
    let cfg = SCStreamConfiguration()
    cfg.width = wantW
    cfg.height = wantH
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.queueDepth = 3
    cfg.showsCursor = false
    cfg.scalesToFit = fit
    return cfg
}

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        // CGS init first: a bare script that builds an SCContentFilter without ever touching AppKit
        // traps on CGS_REQUIRE_INIT.  Also the backing scale, needed for the window's native px.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        var native: (w: Int, h: Int)?
        var label: String
        var filter: SCContentFilter
        // A display's own pixels are what fills the canvas either way, so the bbox cannot tell
        // scaled from padded there: the verdict is withheld rather than wrong (see the header).
        var displayOnly = false

        switch kind {
        case "display":
            guard let display = content.displays.first(where: { $0.displayID == wantedID }) else {
                let ids = content.displays.map { String($0.displayID) }.joined(separator: ", ")
                emit("display \(wantedID) is not in the shareable list (have: \(ids))")
                exit(3)
            }
            let cgW = CGDisplayPixelsWide(display.displayID), cgH = CGDisplayPixelsHigh(display.displayID)
            native = (cgW, cgH)
            // `display.width/height` are points; CGDisplayPixelsWide/High are the pixels the stream
            // draws from. Printing both keeps the units from being read as each other.
            label = "display \(wantedID) \(display.width)x\(display.height) pt = \(cgW)x\(cgH) px"
                   + " (scale \(scale))"
            displayOnly = true
            filter = SCContentFilter(display: display, excludingWindows: [])
        default:
            guard let window = content.windows.first(where: { $0.windowID == wantedID }) else {
                emit("window \(wantedID) is not in the shareable list")
                exit(3)
            }
            let ptW = Int(window.frame.width.rounded()), ptH = Int(window.frame.height.rounded())
            native = (Int((window.frame.width * scale).rounded()),
                      Int((window.frame.height * scale).rounded()))
            label = "window \(wantedID) \"\(window.title ?? "-")\""
                  + " native \(ptW)x\(ptH) pt = \(native!.w)x\(native!.h) px @\(scale)x"
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let frame = try await firstFrame(filter: filter, config: configuration(fit: useFit))
        let head = "\(label) asked \(wantW)x\(wantH) scalesToFit=\(useFit) -> "
        guard let frame else {
            emit(head + "no frame in 5 s")
            sem.signal()
            return
        }
        guard let c = measure(frame) else {
            emit(head + "frame \(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame))"
                 + " is not 32BGRA -- cannot measure content")
            sem.signal()
            return
        }
        emit(head + c.describe + " => " + (displayOnly
             ? "INCONCLUSIVE -- a display fills the canvas at 100 % either way; this probe measures"
               + " window filters only"
             : verdict(c, native: native)))
    } catch {
        emit("SCK error: \(error)")
    }
    sem.signal()
}
sem.wait()
