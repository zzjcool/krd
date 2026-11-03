// Count the tiles of a picture on a real screen: one character per tile, and the number that
// matters at the end.
//
// The picture a mirror puts on a terminal is a grid of separate images (8x4 cells each by default),
// and a terminal is free to draw only some of them -- that is issue #257: on a slow link a terminal
// answered `OK` to all 216 transmits and placements and drew a row-major prefix of them, which a
// screenshot reads as "the bottom of the picture is a staircase of the background colour".
//
// The trick that makes this countable instead of debatable: paint the terminal's background a
// colour the picture never is (`--background=#00ff00` in the terminal), then a cell the picture
// never reached is that colour and nothing else is. Every tile is then a rectangle that is either
// "mostly not the background" or "all background", with no thresholds to tune by hand.
//
//   swiftc -O probe/picture_tiles.swift -o /tmp/picture-tiles
//   /tmp/picture-tiles shot.png <ox> <oy> <ncols> <nrows> <tileW> <tileH> <bgR> <bgG> <bgB> [tol] [--find-y]
//
// `--find-y` ignores <oy> and finds the picture's top edge instead: the first row that is ink across
// the picture's whole width *and* still ink one tile height below it. A krd bar is one cell tall, so
// it fails that second test, and everything above the picture on a 1x display fails it too -- which
// is what makes this runnable with a window at an arbitrary position instead of pinning pixels.
//
// ox/oy are the picture's top-left pixel, which the mirror's own log line gives:
//   krd: mirror grid 47x25 cells at 5x12 px, pane ..., origin 1,13, frame ...
//   -> ox = (originCol - 1) * 5, oy = (originRow - 1) * 12   (the frame starts at the pane's cell 1)
//
// A *band* is the same tool with one row: `ncols 1 nrows 1 tileW <frameW> tileH <bandH>` at the
// band's y tells you whether the rows a picture vacated came back to the background or still carry
// the old picture (the "ghost" an erased-row bug leaves behind).
//
// Exits 1 when any tile is missing, so a script can use it as an assertion; 0 when the picture is
// whole. `+` is expected on the last tile row (its cells are clipped to the frame, so the last
// tile's rectangle is finer than one tile) and on the first one; `.` never is.
//
//   scripts/picture-vm-check.sh          drives all of this against the macOS VM in one command.

import Foundation
import CoreGraphics
import ImageIO

var args = CommandLine.arguments
// `--find-y` may come before or after the numbers: take it out first, so the positions below are
// always the same ones.
let findY = args.contains("--find-y")
args.removeAll { $0 == "--find-y" }
guard args.count >= 11 else {
    FileHandle.standardError.write(
        "usage: picture-tiles png ox oy ncols nrows tileW tileH bgR bgG bgB [tol] [--find-y]\n".data(using: .utf8)!)
    exit(2)
}
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(3)
}
let ox = Int(args[2])!, oy0 = Int(args[3])!, ncols = Int(args[4])!, nrows = Int(args[5])!
let tileW = Int(args[6])!, tileH = Int(args[7])!
let bg = (r: Int(args[8])!, g: Int(args[9])!, b: Int(args[10])!)
// How far a pixel may sit from the background and still count as background: colour management
// moves a flat colour by a few counts on its way to the screenshot, and an unrelated colour by far
// more than this (the pixels either side of a green screen are green and not-green).
let tol = args.count >= 12 ? Int(args[11])! : 60
let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(4) }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

func ink(_ x: Int, _ y: Int) -> Bool {
    guard x >= 0, y >= 0, x < w, y < h else { return false }
    let i = (y * w + x) * 4
    let d = abs(Int(px[i]) - bg.r) + abs(Int(px[i + 1]) - bg.g) + abs(Int(px[i + 2]) - bg.b)
    return d > tol
}

/// The pane's rectangle, found as the box the background colour appears in.
///
/// This is what lets the search below ignore everything outside the terminal: the desktop behind and
/// below the window is "ink" too (it is not the background colour), so a row test over the whole
/// image would lock onto the wallpaper -- which is exactly what a first attempt at this did.
func paneBox() -> (x0: Int, y0: Int, x1: Int, y1: Int) {
    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for y in 0..<h {
        for x in 0..<w where !ink(x, y) {
            if x < x0 { x0 = x }; if x > x1 { x1 = x }
            if y < y0 { y0 = y }; if y > y1 { y1 = y }
        }
    }
    guard x1 > x0, y1 > y0 else { return (0, 0, w - 1, h - 1) }
    return (x0, y0, x1, y1)
}

/// Fraction of `x0..<x1` that is ink on row `y`.
func rowInk(_ y: Int, _ x0: Int, _ x1: Int) -> Double {
    guard y >= 0, y < h, x1 > x0 else { return 0 }
    var on = 0
    for x in x0..<x1 where ink(x, y) { on += 1 }
    return Double(on) / Double(x1 - x0)
}

var oy = oy0
if findY {
    // The picture is the tallest run of rows that are ink across the pane: a krd bar is one cell
    // tall and a stats panel is sparse text, so neither can be mistaken for it.
    let box = paneBox()
    var bestStart = 0, bestLen = 0, runStart = 0, runLen = 0
    for y in box.y0...box.y1 {
        if rowInk(y, box.x0, box.x1) > 0.8 {
            if runLen == 0 { runStart = y }
            runLen += 1
            if runLen > bestLen { bestLen = runLen; bestStart = runStart }
        } else {
            runLen = 0
        }
    }
    oy = bestLen >= tileH ? bestStart : oy0
    print("origin-y \(oy)  (pane \(box.x0),\(box.y0)-\(box.x1),\(box.y1), picture \(bestLen) px tall)")
}

var missing = 0, partial = 0
for ty in 0..<nrows {
    var line = ""
    for tx in 0..<ncols {
        var on = 0, total = 0
        for y in (oy + ty * tileH)..<(oy + ty * tileH + tileH) {
            for x in (ox + tx * tileW)..<(ox + tx * tileW + tileW) {
                total += 1
                if ink(x, y) { on += 1 }
            }
        }
        let frac = total > 0 ? Double(on) / Double(total) : 0
        if frac > 0.5 { line += "#" } else if frac > 0.02 { line += "+"; partial += 1 } else { line += "."; missing += 1 }
    }
    print(String(format: "%2d %@", ty, line))
}
print("missing \(missing)  partial \(partial)  of \(ncols * nrows)")
exit(missing == 0 ? 0 : 1)
