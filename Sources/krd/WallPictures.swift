import CoreGraphics
import Foundation
import krdcore

/// Turns a plan into pixels: one picture per panel, with the bars already painted.
///
/// What this is *not*: a frame loop. The wall captures when the desk changes (the 1 s tick decides
/// that), so there is no dedupe, no cache and no stream to keep alive — measured at 92 ms for a
/// whole wall's four panels (design §12, P0).
enum WallPictures {
    /// The capture is asked for at exactly the panel's own size, never above `maxSide` on either
    /// axis: ScreenCaptureKit clamps a bigger request silently, and an image that no longer matches
    /// `s=`/`v=` would be worse than a soft one.
    ///
    /// There used to be a `pixelScale` here - "the terminal said 8x16 but draws device pixels, so
    /// multiply by 2" - and it was the last place in the wall where a picture's size came from a
    /// guess rather than from the layout. The scale now belongs to the *plan* (`PaneGeometry`'s
    /// quality factor), so the panel's `fit.contentWidth` is already the size to capture at.
    static let maxSide = 4096.0

    struct Picture {
        let panel: WallPanel
        /// The picture itself, **RGBA**, exactly `fit.contentWidth x fit.contentHeight`: no bars,
        /// no padding. The placement is the same rectangle in cells (`fit.cellRect`), so the
        /// terminal stretches the picture over exactly the box the fit chose and there is nothing
        /// left over to draw.
        ///
        /// WHY this is not a panel-sized canvas any more: it used to be, with the fit's bars left
        /// transparent for the wall's background to show through. Terminals do not all agree on what
        /// a transparent image pixel means - Rex paints it **black** - so a picture that occupied
        /// 64% of its canvas came out as a picture inside a black frame, which the reader reports as
        /// "the display is smaller than its frame, with a black ring around it". The mirror never had
        /// this because it places tiles: nothing outside a tile exists. A panel is now the same
        /// shape: the cells are the rectangle, and cells outside it are simply not painted (the
        /// placeholder frame is drawn on `cellRect` too, so mask and picture still coincide).
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    /// Capture every panel, in order, one at a time.
    ///
    /// Sequential on purpose: all four captures go through the same screen-recording service, the
    /// measurements were taken that way, and running them at once buys nothing a reader can see. A
    /// panel that fails is simply absent — the caller paints its mask.
    /// Draw the test pattern instead of the desk (`--demo`). Set once before the first paint.
    static var demo = false
    /// Square corners (`--square`). Rounded is the default: a picture is the size of its cells, so a
    /// cut corner shows the wall underneath, not a frame around a smaller picture (§6.6).
    static var square = false
    /// `--wall-quality`: how far a panel's colour may drop before zlib (issue #88, `QualityBudget`).
    /// Set once before the first paint, like `demo` and `square`.
    ///
    /// Lossy *only in bit depth*: the picture keeps every pixel `WallPanels.plan` gave it, because the
    /// landing screen's rule is that the picture is its cells (§6.6, #121) - so this knob can never
    /// re-open "a smaller picture in the same box", and it can never show a seam. What it buys is
    /// bytes on the wire and, because quantised pixels are more repetitive, a cheaper deflate.
    static var quality = QualityBudget.wall

    /// A panel's pixels after `--wall-quality`. 4 bytes per pixel, so the alpha the rounded corners
    /// put in their holes survives untouched - this is a colour-depth knob, not an alpha one.
    /// `--wall-quality 100` returns the pixels it was given, byte for byte.
    static func quantised(_ pixels: [UInt8], quality: QualityBudget) -> [UInt8] {
        guard let bits = quality.bits else { return pixels }
        return ScreenWriter.quantise(pixels, bits: bits, bytesPerPixel: 4)
    }

    /// The pictures a wall already has, and what it already put on screen (issue #100).
    ///
    /// Two maps, because a repaint asks two different questions:
    /// - `byKey` — "do I already have this picture?" Keyed by `PanelKey`, i.e. by *what the picture
    ///   is* (source, the source's own shape, the size asked for, the quality rung, the corner
    ///   shape), never by where it is placed. A page step changes placement for nothing and identity
    ///   for the cards, so the stage is never re-photographed and a window that stays on the page
    ///   keeps its payload.
    /// - `sent` — "is that same picture already at this slot, in this rectangle?" Keyed by slot,
    ///   because an image id is per slot: if slot 2 now shows a different window, the payload for
    ///   it has to go out again even though the picture itself is cached.
    ///
    /// Not a stream, not a loop: the wall captures on change, so this is a memo between two paints
    /// and it is cleared whenever the terminal's images are (`Desk.runWall`, right after the
    /// `writer.clear()` that drops them).
    final class PanelCache {
        /// How many pictures are worth keeping. A picture is RGBA, so 16 of the biggest panel the
        /// wall can ask for (`WallPictures.maxSide` 4096 on both axes would be 64 MiB each — the real
        /// ones are a pane's worth) bounds the memo at roughly a desktop's card count plus a page or
        /// two of history: a two-page back-and-forth stays free, and a model that keeps growing
        /// cannot grow this cache with it.
        static let capacity = 16

        private var byKey: [PanelKey: Picture] = [:]
        /// Least recently used first: a hit or a store moves its key to the end, and the front is
        /// what `store` drops when the cap is reached.
        private var order: [PanelKey] = []
        private var sent: [Int: (key: PanelKey, rect: CellRect)] = [:]

        func picture(for key: PanelKey) -> Picture? {
            guard let picture = byKey[key] else { return nil }
            Self.touch(&order, key)
            return picture
        }

        func store(_ picture: Picture, _ key: PanelKey) {
            byKey[key] = picture
            Self.touch(&order, key)
            // Eviction forgets the *capture* cache only. `sent` keeps its entry because the terminal
            // still holds that picture: an evicted key costs one re-capture, and a panel that is
            // already on screen must never be re-emitted because its pixels fell out of the memo.
            while order.count > Self.capacity {
                byKey.removeValue(forKey: order.removeFirst())
            }
        }

        private static func touch(_ order: inout [PanelKey], _ key: PanelKey) {
            if let at = order.firstIndex(of: key) { order.remove(at: at) }
            order.append(key)
        }

        /// Is this key's picture already placed on this slot at this exact rectangle? Both halves
        /// matter: the key alone is "the terminal holds the pixels", the rectangle is "where it
        /// draws them" — a moved placement must be re-emitted.
        func isOnScreen(slot: Int, key: PanelKey, rect: CellRect) -> Bool {
            guard let placed = sent[slot] else { return false }
            return placed.key == key && placed.rect == rect
        }

        func didPlace(slot: Int, key: PanelKey, rect: CellRect) {
            sent[slot] = (key: key, rect: rect)
        }

        /// This slot no longer shows the picture it recorded — it paints a mask (the capture failed),
        /// so the text layer has written over those cells.
        ///
        /// Without this, `sent` outlives a failed capture and the *next* paint of the same window
        /// skips the emit ("already on screen") — and the reader keeps the mask on top of a picture
        /// that is not there. The captured payload stays in `byKey`: the picture is not wrong, it is
        /// just not on screen any more.
        func forget(slot: Int) {
            sent.removeValue(forKey: slot)
        }

        /// Forget everything: the terminal no longer holds these images (the wall dropped them, or a
        /// new process is painting a pane that used to hold a mirror's pictures).
        func reset() {
            byKey.removeAll()
            order.removeAll()
            sent.removeAll()
        }

        /// How many distinct pictures are cached — the number a test (and the log) can check.
        var count: Int { byKey.count }
    }

    static func capture(_ panels: [WallPanel], cache: PanelCache? = nil)
        async -> (pictures: [Picture], failures: [Int: PanelCaptureError], reused: Set<Int>) {
        var pictures: [Picture] = []
        var failures: [Int: PanelCaptureError] = [:]
        var reused: Set<Int> = []
        for panel in panels {
            // What this panel's pixels would be, before spending a capture on finding out.
            let key = panel.key(quality: Self.quality.value, rounded: !Self.square)
            if let cached = cache?.picture(for: key) {
                // The *current* panel with the cached pixels: the picture is what a slot wants drawn,
                // and a panel that kept its key but moved keeps its payload — not its old rectangle.
                pictures.append(Picture(panel: panel, pixels: cached.pixels,
                                        width: cached.width, height: cached.height))
                reused.insert(panel.slot)
                Log.write("krd: wall slot \(panel.slot) picture reused "
                          + "\(cached.width)x\(cached.height) px (\(panel.stamp.label))\n")
                continue
            }
            do {
                // Asked in the *content's* aspect, so ScreenCaptureKit's own scaling produces the
                // picture at exactly the size it will occupy and nothing is cropped (P0: SCK scales
                // to fit, anchored top-left, and pads with black only when the aspects disagree).
                // The picture is asked for in the pixels it will be drawn at, not in the box's
                // reported pixels: see `pixelScale`. Both axes share one factor, so the aspect the
                // fit chose is untouched.
                var wantW = Double(panel.fit.contentWidth)
                var wantH = Double(panel.fit.contentHeight)
                let shrink = min(1, Self.maxSide / max(wantW, wantH))
                wantW *= shrink
                wantH *= shrink
                let width = max(1, Int(wantW.rounded()))
                let height = max(1, Int(wantH.rounded()))
                if Self.demo {
                    // The same size the capture would have produced, at the same aspect: the demo is
                    // only useful if it travels the identical path (`width`/`height` above come from
                    // the panel, so the pattern is fitted like a desktop would be).
                    let pixels = DemoPicture.render(width: width, height: height)
                    Log.write("krd: demo picture on slot \(panel.slot): "
                              + "\(panel.rect.cols)x\(panel.rect.rows) cells, "
                              + "\(width)x\(height) px\n")
                    // The demo takes the same path as a capture, quantisation included: a byte count
                    // measured on the demo is only worth reporting if it is the real encoder's.
                    let picture = Picture(panel: panel,
                                          pixels: Self.quantised(pixels, quality: Self.quality),
                                          width: width, height: height)
                    cache?.store(picture, key)
                    pictures.append(picture)
                    continue
                }
                let image: CGImage
                switch panel.source {
                case let .display(id):
                    image = try await PanelCapture.display(id: id, width: width, height: height)
                case let .window(id):
                    image = try await PanelCapture.window(id: id, width: width, height: height)
                }
                // Exactly the panel's pixels, whatever the capture could give: see `PanelRaster.rgb`.
                guard let raster = PanelRaster.rgb(image,
                                                   width: panel.fit.contentWidth,
                                                   height: panel.fit.contentHeight) else {
                    throw PanelCaptureError.noPixelBuffer
                }
                if image.width != panel.fit.contentWidth || image.height != panel.fit.contentHeight {
                    // Worth one line: this is the difference between "the desktop fills its box" and
                    // "the desktop sits in the top-left corner of it" on a terminal that does not
                    // scale a placement to its cells.
                    Log.write("krd: wall slot \(panel.slot) capture \(image.width)x\(image.height) px, "
                              + "scaled to \(panel.fit.contentWidth)x\(panel.fit.contentHeight) px\n")
                }
                let canvas = PanelImage.compose(
                    content: raster.pixels,
                    width: raster.width, height: raster.height,
                    // Panel == content: the corner rounding is the only thing compose adds here.
                    panelWidth: raster.width,
                    panelHeight: raster.height,
                    originX: 0,
                    originY: 0,
                    // Rounded corners, back by request - and the reason they were removed was the
                    // *other* bug. A cut corner is a hole, and the terminal puts its own background
                    // in it, so a rounded picture with a black canvas behind it read as "a frame
                    // around a smaller picture". The canvas was the bug: ScreenCaptureKit pads with
                    // black instead of upscaling (`PanelCapture.fitted`), so the picture's own pixels
                    // held a desktop in one corner. With the picture equal to its cells, the corner
                    // hole is inside the picture and shows the wall it lies on, which is what a
                    // rounded window looks like.
                    cornerRadius: square ? 0
                        : PanelImage.cornerRadius(width: raster.width, height: raster.height))
                guard canvas.count == raster.width * raster.height * 4 else {
                    throw PanelCaptureError.noPixelBuffer
                }
                let picture = Picture(panel: panel,
                                      pixels: Self.quantised(canvas, quality: Self.quality),
                                      width: raster.width, height: raster.height)
                cache?.store(picture, key)
                pictures.append(picture)
            } catch {
                let reason = PanelCapture.classify(error)
                failures[panel.slot] = reason
                // A mask is all the reader sees, and it is the same mask for every reason, so a
                // report of "no pictures in the VM" could not be answered from the pane - the one
                // thing that separates a permission answer from a transient stream fault is the
                // classified reason plus the raw error (TROUBLESHOOTING 23b/23c).
                Log.write("krd: wall slot \(panel.slot) has no picture: \(reason); \(error)\n")
            }
        }
        return (pictures, failures, reused)
    }
}
