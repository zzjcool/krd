import Foundation
import CoreGraphics
import ImageIO

// One pixel, cheaply: the assertion primitive that needs no vision model.
//
// A whole frame is ~100 KB and a vision read; a pixel is 24 bytes and an exit code. Most "did the
// click do something" questions are answered by `changed:<hash>` or by one probe on a control that
// flips colour when selected — and a run that can afford to poll a pixel once a second is a run
// that can assert *after* every step instead of at the end.

func runProbe(_ args: Args) -> Never {
    guard args.positional.count >= 2,
          let x = Double(args.positional[0]), let y = Double(args.positional[1]) else {
        fail(EXIT_USAGE, "probe needs x y in screen points")
    }
    // A small rect rather than 1x1: screencapture rounds edges and a 1-pixel capture can land on a
    // half-pixel boundary, so sampling a 6x6 box and averaging in a 1x1 context is steadier.
    let pad = max(1, args.int("pad", 3))
    let rect = "\(Int(x) - pad),\(Int(y) - pad),\(pad * 2),\(pad * 2)"
    let tmp = NSTemporaryDirectory() + "kagent-probe-\(getpid()).png"
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-t", "png", "-R", rect, tmp]
    let err = Pipe()
    process.standardError = err
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          FileManager.default.fileExists(atPath: tmp),
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: tmp) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        fail(EXIT_REFUSED, "probe could not capture at \(x),\(y): " + message
            + " — Screen Recording is not granted, or the display is asleep")
    }

    var pixel = [UInt8](repeating: 0, count: 4)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail(EXIT_ENVIRONMENT, "cannot allocate a 1x1 bitmap")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))

    let r = Int(pixel[0]), g = Int(pixel[1]), b = Int(pixel[2])
    let json: [String: Any] = [
        "x": x, "y": y,
        "rgb": [r, g, b],
        "hex": String(format: "#%02x%02x%02x", r, g, b),
    ]
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}
