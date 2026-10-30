import Foundation
import AppKit
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// The eyes: capture the screen (or one window), draw the agent's overlays, and hand back a frame
// small enough to read plus the numbers that make a coordinate in that frame a coordinate on the
// screen.
//
// Why the overlays live here and not on the agent's side: a screenshot is 2.3 M pixels and the
// agent's own resampling is a silent source of off-by-a-scale-factor clicks. Doing the scale, the
// grid and the numbered element boxes in one place means one contract ("divide by `scale`, add
// `bounds.origin`") instead of two half-contracts that disagree.

struct Mark {
    let n: Int
    let rect: CGRect
    let label: String
    let kind: String
}

func loadMarks(_ path: String) -> [Mark] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let any = try? JSONSerialization.jsonObject(with: data) else {
        fail(EXIT_USAGE, "cannot read marks file \(path)")
    }
    let rows: [[String: Any]]
    if let dict = any as? [String: Any], let list = dict["marks"] as? [[String: Any]] {
        rows = list
    } else if let list = any as? [[String: Any]] {
        rows = list
    } else {
        fail(EXIT_USAGE, "marks file must be a JSON array or {\"marks\": [...]}")
    }
    return rows.compactMap { row in
        guard let n = row["n"] as? Int ?? (row["n"] as? NSNumber)?.intValue,
              let r = row["rect"] as? [NSNumber], r.count == 4 else { return nil }
        return Mark(n: n,
                    rect: CGRect(x: r[0].doubleValue, y: r[1].doubleValue,
                                 width: r[2].doubleValue, height: r[3].doubleValue),
                    label: row["label"] as? String ?? "",
                    kind: row["kind"] as? String ?? "")
    }
}

func capture(_ args: Args, to path: String, tmp: String) -> (CGRect, CGRect) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    var argv = ["-x", "-o", "-t", "png"]
    if let window = args.opt("window") {
        argv += ["-l", window]
    }
    if let rect = args.opt("rect") {
        argv += ["-R", rect]
    }
    argv.append(tmp)
    process.arguments = argv
    let err = Pipe()
    process.standardError = err
    do { try process.run() } catch {
        fail(EXIT_ENVIRONMENT, "cannot run screencapture: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: tmp) else {
        fail(EXIT_REFUSED, "screencapture failed (\(process.terminationStatus)): "
            + message.trimmingCharacters(in: .whitespacesAndNewlines)
            + " — Screen Recording is not granted to this binary, or the display is asleep")
    }
    if !message.isEmpty {
        FileHandle.standardError.write(message.data(using: .utf8)!)
    }

    // Two coordinate spaces, and the agent needs both: the capture's pixels, and the logical
    // points that `krd ax` and CGEvent use. They differ by the display's backing scale.
    let bounds: CGRect
    if let window = args.opt("window").flatMap({ Int($0) }) {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window))
            as? [[String: Any]] ?? []
        let frame = (list.first?[kCGWindowBounds as String] as? [String: Any]).map { dict in
            CGRect(x: dict["X"] as? CGFloat ?? 0, y: dict["Y"] as? CGFloat ?? 0,
                   width: dict["Width"] as? CGFloat ?? 0, height: dict["Height"] as? CGFloat ?? 0)
        }
        bounds = frame ?? CGRect(origin: .zero, size: CGDisplayBounds(CGMainDisplayID()).size)
    } else if let rect = args.opt("rect") {
        let parts = rect.split(separator: ",").compactMap { Double($0) }
        bounds = parts.count == 4
            ? CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            : CGDisplayBounds(CGMainDisplayID())
    } else {
        bounds = CGDisplayBounds(CGMainDisplayID())
    }
    _ = path
    return (bounds, CGDisplayBounds(CGMainDisplayID()))
}

func runShot(_ args: Args) -> Never {
    let out = args.opt("out", "/tmp/kagent-shot.jpg")!
    let tmp = NSTemporaryDirectory() + "kagent-shot-\(getpid()).png"
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let (bounds, display) = capture(args, to: out, tmp: tmp)
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: tmp) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail(EXIT_ENVIRONMENT, "the capture is not a readable PNG")
    }

    let maxWidth = args.double("max-width", 1200)
    let scale = min(1.0, maxWidth / Double(image.width))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    // Overlay geometry is authored in *logical points* — the space `krd ax` prints and the space a
    // click takes — so the two conversions the agent never has to do live here: points -> capture
    // pixels -> delivered pixels.
    let px = scale
    let logicalToCapture = Double(image.width) / max(1, bounds.width)
    let pxMark = logicalToCapture * px

    let colourSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: colourSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail(EXIT_ENVIRONMENT, "cannot allocate a \(width)x\(height) bitmap")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // AppKit text drawing needs a graphics context, and its y axis is flipped relative to CGImage.
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.current = previous }

    let font = NSFont.monospacedSystemFont(ofSize: max(9, 11 * px), weight: .semibold)
    let small = NSFont.monospacedSystemFont(ofSize: max(8, 9 * px), weight: .regular)

    if let step = args.opt("grid").flatMap({ Double($0) }), step > 0 {
        // A grid the model can count, labelled in screen points: a line at "400" is x=400 for
        // `kagent click`, so nothing in the picture needs converting by hand.
        context.setLineWidth(max(0.5, px))
        context.setStrokeColor(NSColor(calibratedRed: 0.1, green: 1.0, blue: 0.6, alpha: 0.35).cgColor)
        var x = 0.0
        while x <= Double(image.width) / logicalToCapture {
            let xp = x * pxMark
            context.move(to: CGPoint(x: xp, y: 0))
            context.addLine(to: CGPoint(x: xp, y: Double(height)))
            context.strokePath()
            if x > 0 {
                let text = "\(Int(x))" as NSString
                text.draw(at: NSPoint(x: xp + 2 * px, y: Double(height) - 14 * px),
                          withAttributes: [.font: small,
                                           .foregroundColor: NSColor(calibratedRed: 0.1, green: 1.0,
                                                                     blue: 0.6, alpha: 0.8)])
            }
            x += step
        }
        var y = 0.0
        while y <= Double(image.height) / logicalToCapture {
            let yp = Double(height) - y * pxMark
            context.move(to: CGPoint(x: 0, y: yp))
            context.addLine(to: CGPoint(x: Double(width), y: yp))
            context.strokePath()
            if y > 0 {
                let text = "\(Int(y))" as NSString
                text.draw(at: NSPoint(x: 2 * px, y: yp + 1 * px),
                          withAttributes: [.font: small,
                                           .foregroundColor: NSColor(calibratedRed: 0.1, green: 1.0,
                                                                     blue: 0.6, alpha: 0.8)])
            }
            y += step
        }
    }

    var drawn: [[String: Any]] = []
    if let marksPath = args.opt("marks") {
        for mark in loadMarks(marksPath) {
            let r = CGRect(x: (mark.rect.minX * pxMark),
                           y: Double(height) - (mark.rect.maxY * pxMark),
                           width: mark.rect.width * pxMark, height: mark.rect.height * pxMark)
            let tint = mark.kind == "field"
                ? NSColor(calibratedRed: 0.2, green: 0.7, blue: 1.0, alpha: 1.0)
                : NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.45, alpha: 1.0)
            context.setStrokeColor(tint.cgColor)
            context.setLineWidth(max(1, 1.5 * px))
            context.stroke(r)
            context.setFillColor(tint.withAlphaComponent(0.10).cgColor)
            context.fill(r)

            let badge = "\(mark.n)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                             .foregroundColor: NSColor.black]
            let size = badge.size(withAttributes: attributes)
            let pad = 2.0 * px
            let box = CGRect(x: r.minX, y: r.maxY - size.height - 2 * pad,
                             width: size.width + 2 * pad, height: size.height + pad)
            context.setFillColor(tint.cgColor)
            context.fill(box)
            badge.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attributes)
            drawn.append(["n": mark.n, "role": mark.kind, "label": mark.label,
                          "rect": [Int(mark.rect.minX), Int(mark.rect.minY),
                                   Int(mark.rect.width), Int(mark.rect.height)]])
        }
        let found = "\(drawn.count) marks" as NSString
        found.draw(at: NSPoint(x: 4 * px, y: Double(height) - 16 * px),
                   withAttributes: [.font: small, .foregroundColor: NSColor.white])
    }

    if args.opt("cursor") != nil, let pointer = CGEvent(source: nil)?.location {
        // Draw where the pointer is in *capture* pixels: the check that a click landed where the
        // agent meant it to, without a second screenshot.
        let x = (pointer.x - bounds.minX) * Double(image.width) / bounds.width * px
        let y = Double(height) - (pointer.y - bounds.minY) * Double(image.height) / bounds.height * px
        let r = 9.0 * px
        context.setStrokeColor(NSColor.systemYellow.cgColor)
        context.setLineWidth(max(1, 2 * px))
        context.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        context.move(to: CGPoint(x: x - r * 1.6, y: y))
        context.addLine(to: CGPoint(x: x + r * 1.6, y: y))
        context.move(to: CGPoint(x: x, y: y - r * 1.6))
        context.addLine(to: CGPoint(x: x, y: y + r * 1.6))
        context.strokePath()
    }

    guard let flat = context.makeImage() else { fail(EXIT_ENVIRONMENT, "cannot read back the bitmap") }

    // A coarse signature, one luminance byte per 32x24 block of the *capture*. Exact hashes are the
    // wrong tool for "did anything change": a blinking text caret flips a hash 60 times a minute and
    // turns every `same:` assertion into a coin flip. A caret moves one block out of 768; a menu
    // moves dozens. The caller compares with a tolerance, which is the difference between a test
    // that measures the product and one that measures the cursor.
    let blockCols = 32, blockRows = 24
    var signature = Data()
    if let small = CGContext(data: nil, width: blockCols, height: blockRows, bitsPerComponent: 8,
                             bytesPerRow: blockCols * 4, space: colourSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: blockCols, height: blockRows))
        if let raw = small.data {
            let bytes = raw.bindMemory(to: UInt8.self, capacity: blockCols * blockRows * 4)
            for i in 0..<(blockCols * blockRows) {
                let r = Double(bytes[i * 4]), g = Double(bytes[i * 4 + 1]), b = Double(bytes[i * 4 + 2])
                // Rec. 601 luma in a single byte: enough to see a picture, cheap enough to compare.
                signature.append(UInt8(max(0, min(255, (0.299 * r + 0.587 * g + 0.114 * b).rounded()))))
            }
        }
    }

    // The hash is over the *capture*, at its own resolution and before any overlay. Two reasons:
    // it must not change because a caller asked for a smaller delivery (`--max-width`) or because
    // this frame carries marks, and "the screen is unchanged" has to mean the screen, not the JPEG.
    var digest = SHA256()
    if let canvas = CGContext(data: nil, width: image.width, height: image.height,
                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                             space: colourSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if let data = canvas.data {
            digest.update(bufferPointer: UnsafeRawBufferPointer(start: data,
                                                               count: canvas.bytesPerRow * image.height))
        }
    }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()

    let format = (args.opt("format", "jpeg") ?? "jpeg").lowercased()
    let type: UTType = format == "png" ? .png : .jpeg
    guard let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: out) as CFURL, type.identifier as CFString, 1, nil) else {
        fail(EXIT_ENVIRONMENT, "cannot write \(out)")
    }
    let quality = args.double("quality", 0.72)
    CGImageDestinationAddImage(destination, flat, [
        kCGImageDestinationLossyCompressionQuality: quality,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        fail(EXIT_ENVIRONMENT, "cannot encode \(out)")
    }

    let meta: [String: Any] = [
        "path": out,
        "format": format,
        "captured": ["width": image.width, "height": image.height],
        "delivered": ["width": width, "height": height],
        // Multiply a delivered-image coordinate by `scale` and add `bounds.origin` to get a
        // screen point that `kagent click` understands.
        "scale": Double(image.width) / Double(width),
        "bounds": ["x": bounds.minX, "y": bounds.minY,
                   "width": bounds.width, "height": bounds.height],
        "display": ["width": display.width, "height": display.height],
        // Pixels per logical point in the capture: 2 on a Retina display, 1 in the VM.
        "native_scale": Double(image.width) / max(1, bounds.width),
        "hash": hash,
        "signature": signature.base64EncodedString(),
        "signature_shape": [blockCols, blockRows],
        "bytes": (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0,
        "drawn": drawn,
    ]
    let json = try! JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
    print(String(data: json, encoding: .utf8)!)
    exit(0)
}
