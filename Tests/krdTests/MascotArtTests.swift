import XCTest
@testable import krd
import krdcore

/// The generated mascot: what has to be true of `MascotArt` and of the drawing `MascotRaster`
/// makes of it, whatever the drawing happens to look like this month.
///
/// The drawing itself lives in `docs/brand/tui/mascot.mjs` and is not something a Swift test can
/// reach, so the drift alarm is `make mascot-check` (regenerate, `cmp`, and the lab's own layout
/// self-test). What is asserted *here* is the other half: that the file which was generated is a
/// drawing this renderer can actually draw — every string parses, every group resolves, every
/// colour the mosaic might need is in the palette — and that what comes out of CoreGraphics is a
/// recognisable crab rather than a rectangle of one colour.
///
/// Deliberately not a byte-for-byte golden: CoreGraphics antialiasing is allowed to differ between
/// macOS releases, and a test that fails on a runner upgrade teaches people to re-baseline without
/// looking. The assertions below are the properties that would still have to hold after a redraw:
/// ink coverage is plausible, the four picture beats differ, the blink closes the eyes, the drawing
/// still carries the one brand-blue dot, and the paper is exactly the paper — which is what makes the
/// card's cells and the picture's own background the same black on screen.
final class MascotArtTests: XCTestCase {
    private let paper = MascotRGB(hex: "#080a10")
    private let blue = MascotRGB(hex: "#5eb8ff")

    // MARK: - the generated file

    /// Eight beats: the mosaic plays all eight at 110 ms, the picture plays the even four at 220 ms.
    /// A generator that changed the count would silently change the animation's length.
    func testTheDrawingHasTheEightBeatsTheCardPlays() {
        XCTAssertEqual(MascotArt.poses.count, 8)
        XCTAssertEqual(MascotArt.layers.count, 22, "the sprite's layer count, pinned by the lab")
        XCTAssertEqual(MascotArt.view.count, 4)
        XCTAssertGreaterThan(MascotArt.view[2], 0)
        XCTAssertGreaterThan(MascotArt.view[3], 0)
    }

    /// Every group a layer names exists, and every group's parent chain terminates. A typo in the
    /// generator would otherwise draw that layer untransformed — a crab with a leg in the wrong place,
    /// which no byte count would show.
    func testEveryGroupResolvesAndTheChainEnds() {
        for (name, group) in MascotArt.groups {
            var seen: Set<String> = [name]
            var parent = group.parent
            while let p = parent {
                XCTAssertNotNil(MascotArt.groups[p], "\(name) has a parent that does not exist: \(p)")
                guard seen.insert(p).inserted else { return XCTFail("group cycle through \(p)") }
                parent = MascotArt.groups[p]?.parent
            }
        }
        for (i, layer) in MascotArt.layers.enumerated() {
            if let group = layer.group {
                XCTAssertNotNil(MascotArt.groups[group], "layer \(i) names group \(group), which is gone")
            }
            if let only = layer.only {
                XCTAssertTrue(["open", "shut"].contains(only), "layer \(i) has an unknown `only`: \(only)")
            }
            XCTAssertFalse(layer.d.isEmpty, "layer \(i) has no path")
        }
    }

    /// Every paint string parses, and a gradient has the two stops CoreGraphics needs. This is the
    /// one place a generator bug would be invisible in a diff: a malformed `@L` string draws nothing.
    func testEveryPaintParses() {
        for (i, layer) in MascotArt.layers.enumerated() {
            for spec in [layer.fill, layer.stroke].compactMap({ $0 }) {
                XCTAssertNotNil(MascotPaint(spec), "layer \(i) has a paint that will not parse: \(spec)")
                if case let .gradient(_, from, to, radial) = MascotPaint(spec)! {
                    XCTAssertTrue(radial || from != to, "layer \(i) has a linear gradient with no axis")
                }
            }
        }
    }

    /// The mosaic quantises to `palette`, so every colour the drawing paints with has to be in it —
    /// otherwise the sprite's outline snaps to the nearest thing in the list and the crab's ink turns
    /// into a slightly wrong brown that nobody notices until it is on a wall.
    func testThePaletteCoversEveryColourTheDrawingUses() {
        let palette = Set(MascotArt.palette.map { $0.lowercased() })
        for (i, layer) in MascotArt.layers.enumerated() {
            for spec in [layer.fill, layer.stroke].compactMap({ $0 }) {
                guard let paint = MascotPaint(spec) else { continue }
                switch paint {
                case .colour:
                    XCTAssertTrue(palette.contains(spec.lowercased()),
                                  "layer \(i) paints \(spec), which is not in the mosaic's palette")
                case .gradient:
                    /* `MascotPaint` keeps the colours to itself; the generator's own guarantee is
                       that every gradient stop is in the list, and `--test` in the lab checks it. */
                    XCTAssertTrue(spec.hasPrefix("@L") || spec.hasPrefix("@R"))
                }
            }
        }
        XCTAssertTrue(palette.contains("#080a10"),
                      "the paper must be in the palette, or the background around the crab is not the "
                      + "background the card paints")
    }

    // MARK: - what the renderer draws

    /// A crab, at the card's own size: ink in the 25–55 % band, and a handful of colours rather than
    /// a gradient — the mosaic is a drawing, not a photograph of one.
    func testTheMosaicIsADrawingAtTheCardsSize() {
        for pose in MascotArt.poses.indices {
            let dots = MascotRaster.render(pose: pose, width: 36, height: 36, aspect: 1.25,
                                           style: .mosaic, paper: paper)
            XCTAssertEqual(dots.count, 36 * 36 * 3)
            let colours = stride(from: 0, to: dots.count, by: 3).map {
                (Int(dots[$0]) << 16) | (Int(dots[$0 + 1]) << 8) | Int(dots[$0 + 2])
            }
            let ink = colours.filter { $0 != (8 << 16 | 10 << 8 | 16) }.count
            let fraction = Double(ink) / Double(36 * 36)
            XCTAssertGreaterThan(fraction, 0.25, "pose \(pose) draws \(fraction * 100) % of the box")
            XCTAssertLessThan(fraction, 0.55, "pose \(pose) draws \(fraction * 100) % of the box")
            XCTAssertGreaterThan(Set(colours).count, 5, "pose \(pose) is nearly one colour")
            XCTAssertLessThan(Set(colours).count, 20, "pose \(pose) is not quantised")
        }
    }

    /// The paper is the paper, edge to edge: the corners of a dot grid have to come out exactly the
    /// colour the card writes into its empty cells, or the sprite sits in a slightly different black
    /// rectangle than the one around it — visible on a dark terminal, and only there.
    func testThePaperIsExactAtTheCorners() {
        let dots = MascotRaster.render(pose: 3, width: 36, height: 36, aspect: 1.25,
                                       style: .mosaic, paper: paper)
        for (x, y) in [(0, 0), (35, 0), (0, 35), (35, 35)] {
            let q = (y * 36 + x) * 3
            XCTAssertEqual([dots[q], dots[q + 1], dots[q + 2]], [paper.r, paper.g, paper.b],
                           "corner (\(x),\(y)) is not the card's paper")
        }
    }

    /// The animation has to be visible: the four frames the picture path sends are four different
    /// drawings, and the blink closes the eyes rather than nudging them.
    func testTheFourPictureBeatsDifferAndTheBlinkClosesTheEyes() {
        let frames = [0, 2, 4, 6].map {
            MascotRaster.render(pose: $0, width: 36, height: 45, aspect: 1, style: .picture, paper: paper)
        }
        /* each step of the cycle changes the drawing; the cycle is symmetric, so beat 2 and beat 6
           are the same picture on purpose (the crab leaves the way it came in) */
        for (a, b) in [(0, 1), (1, 2), (2, 3)] {
            XCTAssertGreaterThan(changed(frames[a], frames[b]), 20,
                                 "frames \(a) and \(b) are nearly the same drawing")
        }
        XCTAssertEqual(changed(frames[1], frames[3]), 0, "the retreat retraces the emergence")
        /* the blink closes the eyes: less cream (the sclera) than the frame before it */
        XCTAssertLessThan(cream(frames[2]), cream(frames[1]) / 2, "the blink did not close the eyes")
        /* the brand's one blue dot lives in the open eyes, at a size that can hold it */
        let hi = MascotRaster.render(pose: 3, width: 128, height: 112, aspect: 1, style: .picture,
                                     paper: paper)
        XCTAssertTrue(hasBlue(hi), "the picture has no brand-blue dot")
    }

    /// The sprite fits its own view: no ink on the border of the 36-dot grid, and the shell's lip
    /// stays inside the box. `spriteView()` computes the union of every beat's bounds and adds a
    /// margin for exactly this — a view that is too tight clips the crab's outline on one side, and a
    /// clipped crab is one of those things that looks like a rendering artefact and is arithmetic.
    func testTheSpriteFitsInsideItsView() {
        for pose in MascotArt.poses.indices {
            let dots = MascotRaster.render(pose: pose, width: 36, height: 36, aspect: 1.25,
                                           style: .mosaic, paper: paper)
            func ink(_ x: Int, _ y: Int) -> Bool {
                let q = (y * 36 + x) * 3
                return !(dots[q] == paper.r && dots[q + 1] == paper.g && dots[q + 2] == paper.b)
            }
            for x in 0..<36 {
                XCTAssertFalse(ink(x, 0), "pose \(pose) touches the top edge at column \(x)")
                XCTAssertFalse(ink(x, 35), "pose \(pose) touches the bottom edge at column \(x)")
            }
            for y in 0..<36 {
                XCTAssertFalse(ink(0, y), "pose \(pose) touches the left edge at row \(y)")
                XCTAssertFalse(ink(35, y), "pose \(pose) touches the right edge at row \(y)")
            }
        }
    }

    // MARK: - helpers

    /// How many pixels differ by more than a rounding step: "these are two drawings", not "these are
    /// two renderings of one drawing".
    private func changed(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 3) {
            let dr = abs(Int(a[i]) - Int(b[i]))
            let dg = abs(Int(a[i + 1]) - Int(b[i + 1]))
            let db = abs(Int(a[i + 2]) - Int(b[i + 2]))
            if dr + dg + db > 24 { n += 1 }
        }
        return n
    }

    /// How much of the picture is sclera: the blink turns the whites into the lid's coral.
    private func cream(_ bytes: [UInt8]) -> Int {
        let sclera = MascotRGB(hex: "#fffaf2")
        return stride(from: 0, to: bytes.count, by: 3).reduce(0) { n, i in
            let dr = abs(Int(bytes[i]) - Int(sclera.r))
            let dg = abs(Int(bytes[i + 1]) - Int(sclera.g))
            let db = abs(Int(bytes[i + 2]) - Int(sclera.b))
            return dr + dg + db < 60 ? n + 1 : n
        }
    }

    /// Is the brand's blue in the picture at all? Compared loosely: at 36 px the dot is one or two
    /// pixels and antialiasing blends it.
    private func hasBlue(_ bytes: [UInt8]) -> Bool {
        stride(from: 0, to: bytes.count, by: 3).contains { i in
            let dr = abs(Int(bytes[i]) - Int(blue.r))
            let dg = abs(Int(bytes[i + 1]) - Int(blue.g))
            let db = abs(Int(bytes[i + 2]) - Int(blue.b))
            return dr < 40 && dg < 40 && db < 40
        }
    }
}
