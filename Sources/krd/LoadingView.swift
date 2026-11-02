import Foundation
import krdcore

/// The mascot card krd shows while the first frame is still in flight.
///
/// One picture, two transports — and the transport is decided once, by a probe, never guessed.
///
/// **The terminal animates it when it can** (`animates: true`, i.e. the `a=f` probe answered yes;
/// issue #217, design §4.3's last bullet and §5.1's "加载动画 < 4 KB/s" row). The old card rasterised
/// 36×36 dots and wrote them as `▀` with per-cell 24-bit SGR **every 110 ms** — ~22.6 KB and 9.09
/// ticks a second on a 137×44 pane, measured, i.e. ~205 KB/s for a picture with four poses. So the
/// four frames are now transmitted *once*: `start()` writes a single `?2026h … ?2026l` block carrying
/// the four frames as `a=t`/`a=f` (gap 220 ms), the two `a=a` that start the loop, and one
/// pixel-sized placement; after that the card writes **0 bytes until `stop()`**, because the
/// animation runs inside the terminal. The budget is met by construction rather than by shrinking the
/// picture: the cost is one transmit (~6.9 KB of base64 here, four 36×45 frames) and then 0 B/s.
///
/// The frames are the *even* beats of the drawing — `MascotArt.poses[2 * i]` for i in 0..<4 — so
/// 4 × 220 ms is the same 880 ms blink as 8 × 110 ms was, and the blink itself is not redesigned (D1). The pixel box is
/// derived from the cell the caller measured, not from a constant, so the picture's pixel aspect
/// equals the cell box's whichever way the terminal scales it (D2, `pictureHeight`).
///
/// **The card animates it when it cannot** (`animates: false`: no `a=f`, or the probe said nothing):
/// the `▀` mosaic, the 110 ms `DispatchSourceTimer`, the `frame % 4` ellipsis (D5) — the transport is
/// untouched by #217 and by the redraw. That is deliberate: a terminal that cannot animate gets the
/// card it always got *through the same path*, because a degrade that also changes how the card is
/// drawn is a second bug on a path nobody can reproduce remotely. The drawing inside it is the new
/// one (`MascotArt` at `lo`), because a fallback that shows a different crab than the picture is the
/// drift this whole arrangement exists to kill. `tick()` is that timer's handler, exposed so the
/// fallback's cost can be measured (`LoadingViewTests`) without a clock.
///
/// The drawing is `MascotArt`, generated from `docs/brand/tui/mascot.mjs` by
/// `node docs/brand/tui/logo-tui.mjs --swift` and drawn by `MascotRaster` with CoreGraphics. This
/// file no longer holds a single shape: the crab exists once, as paths, and the README's SVG, the
/// lab's sprites, the favicon and this card are renderers of that one drawing. The hand-drawn
/// twelve-shape version that used to live here is what that buys — it had already drifted from the
/// brand's own picture, and nothing but a test could have noticed.
///
/// `stop()` is idempotent and is called from the frame path: the first frame that lands takes the
/// card away, nothing else does. On the animated path it also deletes the image by id — a
/// pixel-sized placement is *not* erased by clearing cells, so the row clears alone would leave a
/// mascot floating over the picture that just arrived — and forgets the `IconCache` entry, so a
/// second card in this process re-transmits instead of placing an image the terminal no longer holds
/// (D4). Every APC goes through `GraphicsAPC.sequence` (#107: the tmux envelope is ambient, so it
/// cannot be walked around) and every one of them is `q=2`, so nothing here can put a reply on stdin
/// after `startInput()` owns it.
final class LoadingView {
    /// The card's paper: the same near-black the brand's picture uses, so a terminal whose own
    /// background is dark shows the card as a picture rather than as a rectangle.
    private static let paper = MascotRGB(hex: "#080a10")

    private static let dotW = 36, dotH = 36                 // dots; two dots per cell row

    /// 220 ms: the gap the terminal plays the four frames at. Half of the old 110 ms tick because
    /// the animation now carries the even steps of `peek`, so 4 × 220 = 880 ms is the cycle the
    /// mosaic had at 8 × 110 (D1). The gap lives on the `a=f` frames and on the `a=a` that starts
    /// the loop — a base image carries no gap of its own, so without the second one nothing plays.
    private static let frameGapMs = 220

    /// The dot grid's cell box: 36 columns, 18 rows. The animated path places the picture over it,
    /// so both transports cover the same cells (and `stop()` clears the same 20 rows for both).
    private static let cellCols = dotW, cellRows = dotH / 2

    // MARK: state

    private let writeText: (String) -> Void
    private let paneCols: Int
    private let paneRows: Int
    /// Which transport this card got, decided once by the probe before the card exists (D5). Never
    /// re-decided here: the picture path and the mosaic path draw different things, and a mid-flight
    /// switch would leave the terminal holding an image nobody deletes.
    private(set) var animates: Bool
    /// The cell the caller measured. Only the animated path reads it (`pictureHeight`); the mosaic is
    /// expressed in cells and needs no pixel size.
    private let cell: (w: Double, h: Double)
    private let cache: IconCache
    private let palette: UInt64
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private var painted = false
    /// The image the terminal is holding, while it holds it: the id `stop()` has to delete, and the
    /// graphic `IconCache.forget` needs to drop the book. `nil` on the mosaic path (`animates:
    /// false`) and after `stop()` — the two states in which there is nothing to take away.
    private var picture: (id: Int, graphic: IconCache.Graphic)?

    init(paneCols: Int, paneRows: Int, cell: (w: Double, h: Double),
         animates: Bool = false, cache: IconCache = IconCache(), paletteKey: UInt64 = 0,
         write: @escaping (String) -> Void) {
        self.paneCols = paneCols
        self.paneRows = paneRows
        self.cell = cell
        self.animates = animates
        self.cache = cache
        self.palette = paletteKey
        self.writeText = write
    }

    private var originRow: Int { max(0, (paneRows - (Self.cellRows + 2)) / 2) }
    private var originCol: Int { max(0, (paneCols - Self.cellCols) / 2) + 1 }

    func start() {
        guard timer == nil, !painted else { return }
        if animates {
            startPicture()
        } else {
            paint()
            startMosaic()
        }
    }

    /// The fallback's clock: unchanged from before #217, 110 ms repeating, and it exists only on
    /// this path. The picture path has no timer at all — that *is* the saving.
    private func startMosaic() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(110), repeating: .milliseconds(110))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        if let t = timer {
            t.cancel()
            timer = nil
        }
        guard painted else { return }
        painted = false
        // Clear exactly what we drew: the card's rows, nothing else. The frame path owns the rest.
        var out = ""
        for row in 0..<(Self.cellRows + 2) {
            out += "\u{1B}[\(originRow + row + 1);1H\u{1B}[2K"
        }
        // A pixel-sized placement is not part of the text grid: blanking the cells under it leaves
        // the picture on screen, floating over the frame that just arrived, until something else
        // deletes it — and the writer's own `clear()` runs before the card, not after it (D4).
        if let picture {
            out += GraphicsAPC.sequence("Gi=\(picture.id),a=d,d=i,i=\(picture.id)")
            cache.forget(picture.graphic, palette: palette)
            self.picture = nil
        }
        out += "\u{1B}[\(originRow + 1);1H"
        writeText(out)
    }

    /// One beat of the fallback's animation: exactly what the timer's handler has always done.
    ///
    /// Exposed because it is the only way to measure the mosaic without a clock — the budget is
    /// judged on bytes per tick, and a test that slept 110 ms nine times would be a test that fails
    /// on a loaded machine (D3's note; issue #217's acceptance). On the picture path a tick writes
    /// nothing: the terminal owns the animation, so there is nothing to repaint.
    func tick() {
        guard !animates else { return }
        frame += 1
        paint()
    }

    // MARK: the picture (the terminal animates it)

    /// The one write of the animated card: blank the card's rows, park the cursor on the picture's
    /// cell box, hand over the frames and the placement, and label it.
    ///
    /// The `?2026` block is the caller's, not the cache's (`IconCache.Emit` says so): a nested pair
    /// would end this block early, and the whole point of one block is that a slow link never shows
    /// half a card — twenty blank rows with no mascot in them.
    ///
    /// The label is written *after* the picture and outside the block, the way a re-place is: text is
    /// cheap and it must not be able to disturb a transmit that is still assembling.
    private func startPicture() {
        let graphic = makeGraphic()
        let emit = cache.draw(graphic, palette: palette,
                              at: .pixels(cols: Self.cellCols, rows: Self.cellRows))
        // `id 0` is the cache refusing the picture (a frame that will not compress): there is then
        // nothing on screen to delete, and `a=d,i=0` would be a delete of nothing.
        if emit.id > 0 { picture = (emit.id, graphic) }
        painted = true
        var out = "\u{1B}[?2026h"
        for row in 0..<(Self.cellRows + 2) {
            out += "\u{1B}[\(originRow + row + 1);1H\u{1B}[2K"
        }
        out += "\u{1B}[\(originRow + 1);\(originCol)H"
        out += emit.bytes
        out += "\u{1B}[?2026l"
        out += labels()
        writeText(out)
    }

    /// The four frames, at the size the terminal's own scaler wants (D1/D2).
    ///
    /// `IconCache.Graphic` compresses, chunks and numbers them: the id bookkeeping lives in krdcore
    /// so that a second card (or the chrome, later) can place an image this one already sent.
    private func makeGraphic() -> IconCache.Graphic {
        let height = Self.pictureHeight(cellW: cell.w, cellH: cell.h)
        /* the even beats of the eight: 4 frames x 220 ms is the 880 ms cycle the mosaic had at
           8 x 110 ms, and the blink stays where it was (D1) */
        let frames = (0..<4).map { i in
            IconImage(width: Self.dotW, height: height,
                      pixels: MascotRaster.render(pose: 2 * i, width: Self.dotW, height: height,
                                                  aspect: 1, style: .picture,
                                                  paper: Self.paper))
        }
        return IconCache.Graphic(frames: frames, gapMs: Self.frameGapMs)
    }

    /// The picture's pixel height from the cell the caller measured (D2).
    ///
    /// `36 × round(36 · cellH / (2 · cellW))`: the dot grid is 36 dots across a 36-cell box and 36
    /// dot rows down its 18 rows, so a picture whose *pixel* aspect equals that box's *cell* aspect
    /// is 36 wide and `18 · cellH / cellW` tall — 45 on an 8×20 cell, 35 on a 17×33 one. That is the
    /// whole point of deriving it from `cell:` instead of hard-coding it: a terminal that stretches
    /// a `c`/`r` placement to fill the box and one that fits it with the aspect preserved then agree
    /// with each other, and both agree with the mosaic the fallback draws.
    ///
    /// The guard is not arithmetic paranoia: `Int(_:)` traps on infinity, so a `0 x 0` cell (a pane
    /// that has not been measured yet) would crash the one card that is painted *before* anything
    /// else is proven. 45 is the 8×20 cell's own answer, which is what an unmeasured pane gets.
    private static func pictureHeight(cellW: Double, cellH: Double) -> Int {
        guard cellW > 0, cellH > 0 else { return 45 }
        return max(1, Int((Double(dotW) * cellH / (2 * cellW)).rounded()))
    }

    // MARK: the mosaic (the card animates it)

    private func paint() {
        let dots = Self.mosaicDots(pose: frame, cell: cell)
        var out = ""
        for row in 0..<Self.cellRows {
            out += "\u{1B}[\(originRow + row + 1);1H\u{1B}[2K"
            out += String(repeating: " ", count: originCol)
            for col in 0..<Self.dotW {
                let t = ((row * 2) * Self.dotW + col) * 3
                let b = ((row * 2 + 1) * Self.dotW + col) * 3
                out += "\u{1B}[38;2;\(dots[t]);\(dots[t + 1]);\(dots[t + 2]);48;2;"
                out += "\(dots[b]);\(dots[b + 1]);\(dots[b + 2])m▀"
            }
            out += "\u{1B}[0m"
        }
        out += labels()
        painted = true
        writeText(out)
    }

    /// The two caption rows, in the card's own colours, centred on the dot grid.
    ///
    /// `frame` drives the ellipsis and nothing else, which is why the picture path can write this
    /// once: frame 0 is the bare label, and there is no second frame to add a dot to. Keeping the
    /// pulse here (rather than in `paint`) is what makes "only the mosaic's timer moves the caption"
    /// a property of one function that both paths call.
    private func labels() -> String {
        let label = "waiting for first frame" + String(repeating: ".", count: (frame % 4))
        let sub = "krd · connecting"
        let pad = max(0, (Self.dotW - label.count) / 2)
        var out = "\u{1B}[\(originRow + Self.cellRows + 1);1H\u{1B}[2K"
        out += String(repeating: " ", count: originCol + pad)
        out += "\u{1B}[38;2;140;150;170m\(label)\u{1B}[0m"
        let pad2 = max(0, (Self.dotW - sub.count) / 2)
        out += "\u{1B}[\(originRow + Self.cellRows + 2);1H\u{1B}[2K"
        out += String(repeating: " ", count: originCol + pad2)
        out += "\u{1B}[38;2;88;98;118m\(sub)\u{1B}[0m"
        return out
    }

    /// The 36x36 dot grid, one dot per half block: a dot is `cellW` wide and `cellH / 2` tall, so
    /// the drawing is stretched by `cellH / (2 * cellW)` (1.25 on an 8x20 cell) to keep its own
    /// proportions on screen instead of looking like a crab seen through a letterbox.
    ///
    /// `style: .mosaic` is the mosaic's rule and the picture's difference: one colour per dot,
    /// decided by the majority of its samples, because an averaged half-block edge is a third colour
    /// nobody chose and this sprite is mostly edges.
    static func mosaicDots(pose: Int, cell: (w: Double, h: Double)) -> [UInt8] {
        let aspect = cell.w > 0 && cell.h > 0 ? cell.h / (2 * cell.w) : 1.25
        return MascotRaster.render(pose: pose, width: dotW, height: dotH, aspect: aspect,
                                   style: .mosaic, paper: paper)
    }
}
