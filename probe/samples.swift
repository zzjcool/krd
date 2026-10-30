// Three images to measure a terminal's grey/palette support against, at krd's real capture size
// (2329x1452 = a 137x60 pane at 17x33 px cells). Run once, then point gray_probe.py at them:
//
//     swiftc -O probe/samples.swift -o /tmp/samples && /tmp/samples
//     python3 probe/gray_probe.py --image ~/tmp/krd-samples/page.png
//
// page.png      white page of body text   the reading case, where grey wins
// terminal.png  dark terminal, 44 lines   the flat case that made the first measurement look useless
// photo.png     real photograph           the case where 5-6-5 (already shipped) wins instead
//
// Not committed: 3.7 MB of PNGs for numbers anyone can regenerate in two seconds.

import AppKit

let out = NSString(string: "~/tmp/krd-samples").expandingTildeInPath

func canvas(_ w: Int, _ h: Int, _ bg: NSColor) -> (NSBitmapImageRep, CGContext) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    bg.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    return (rep, ctx.cgContext)
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    let path = "\(out)/\(name)"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    let attrs = try! FileManager.default.attributesOfItem(atPath: path)
    print("\(name): \(rep.pixelsWide)x\(rep.pixelsHigh) \((attrs[.size] as! Int) / 1024) KB")
}

func para(_ style: NSMutableParagraphStyle, _ text: String) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black, .paragraphStyle: style])
}

// 1. a browser/article window: dense text, the "reading" case
let (artRep, _) = canvas(2329, 1452, .white)
let art = NSMutableParagraphStyle(); art.lineSpacing = 6; art.paragraphSpacing = 14
let body = String(repeating:
    "The picture is the thing the user reads, so the bytes that carry it are the bytes that matter. "
    + "A page of text is mostly paper: long runs of one colour, then a glyph, then paper again, and "
    + "zlib already finds those runs. What it cannot find is the three identical colour planes the "
    + "protocol makes us send, one per channel, for a photograph that only ever had one.\n", count: 40)
NSAttributedString(string: "Why the wire costs three times what the page is worth\n",
                   attributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.black])
    .draw(in: NSRect(x: 90, y: 1330, width: 1900, height: 60))
para(art, body).draw(in: NSRect(x: 90, y: 90, width: 2140, height: 1220))
NSColor(white: 0.94, alpha: 1).setFill(); NSRect(x: 1560, y: 900, width: 690, height: 420).fill()
save(artRep, "page.png")

// 2. a dark terminal, the case the user was actually looking at
let (termRep, _) = canvas(2329, 1452, NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1))
let mono = NSMutableParagraphStyle(); mono.lineSpacing = 5
let lines = [
    "\u{1b}",              // placeholder never drawn
]
var y = 1380
let monoFont = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
let prompt = NSAttributedString(string: "zheng@zzjs-MacBook-Pro krd % swift test 2>&1 | tail -3\n",
    attributes: [.font: monoFont, .foregroundColor: NSColor(calibratedRed: 0.5, green: 0.9, blue: 0.6, alpha: 1),
                 .paragraphStyle: mono])
prompt.draw(in: NSRect(x: 40, y: CGFloat(y), width: 2250, height: 40)); y -= 40
for i in 0..<44 {
    let text = String(format: "  [%3d/140] Compiling krdTestSupport krdTests_%02d.swift  (\u{25cf} %d.%02ds)\n",
                      i * 3 + 7, i, i / 7, (i * 37) % 100)
    NSAttributedString(string: text, attributes: [.font: monoFont,
        .foregroundColor: NSColor(white: CGFloat(0.55) + CGFloat((i * 13) % 40) / 100, alpha: 1),
        .paragraphStyle: mono]).draw(in: NSRect(x: 40, y: CGFloat(y), width: 2250, height: 30))
    y -= 30
}
save(termRep, "terminal.png")

// 3. a photo: the case where 5-6-5 is what helps
if let src = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/Big Sur Coastline.heic") {
    let (photoRep, ctx) = canvas(2329, 1452, .black)
    let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 2329, height: 1452))
    save(photoRep, "photo.png")
}
