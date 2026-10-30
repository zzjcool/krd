import CoreGraphics
import Foundation
import krdcore

/// Turns a plan into pixels: one picture per panel, with the bars already painted.
///
/// What this is *not*: a frame loop. The wall captures when the desk changes (the 1 s tick decides
/// that), so there is no dedupe, no cache and no stream to keep alive — measured at 92 ms for a
/// whole wall's four panels (design §12, P0).
enum WallPictures {
    /// Device pixels per *reported* pixel for the captures below.
    ///
    /// The fit measures its box in the terminal's own units (`CSI 16t`), and a terminal may report
    /// those in points while drawing an image one device pixel per image pixel: Rex answers 8x16 for
    /// a cell that is 16.7x32.7 device pixels, so a picture sized to the box arrived at half its
    /// width, anchored top-left, and the rest of the identical box showed the terminal's background.
    /// Measured on the wall's own bytes: 1075x672 px in a 135x41 cell box (design §6.6).
    static var pixelScale: Double = 1

    /// The capture is asked for at `contentWidth x contentHeight` * `pixelScale`, never above
    /// `maxSide` on either axis: ScreenCaptureKit clamps a bigger request silently, and an image that
    /// no longer matches `s=`/`v=` would be worse than a soft one.
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
    static func capture(_ panels: [WallPanel]) async -> (pictures: [Picture],
                                                          failures: [Int: PanelCaptureError]) {
        var pictures: [Picture] = []
        var failures: [Int: PanelCaptureError] = [:]
        for panel in panels {
            do {
                // Asked in the *content's* aspect, so ScreenCaptureKit's own scaling produces the
                // picture at exactly the size it will occupy and nothing is cropped (P0: SCK scales
                // to fit, anchored top-left, and pads with black only when the aspects disagree).
                // The picture is asked for in the pixels it will be drawn at, not in the box's
                // reported pixels: see `pixelScale`. Both axes share one factor, so the aspect the
                // fit chose is untouched.
                var wantW = Double(panel.fit.contentWidth) * Self.pixelScale
                var wantH = Double(panel.fit.contentHeight) * Self.pixelScale
                let shrink = min(1, Self.maxSide / max(wantW, wantH))
                wantW *= shrink
                wantH *= shrink
                let width = max(1, Int(wantW.rounded()))
                let height = max(1, Int(wantH.rounded()))
                let image: CGImage
                switch panel.source {
                case let .display(id):
                    image = try await PanelCapture.display(id: id, width: width, height: height)
                case let .window(id):
                    image = try await PanelCapture.window(id: id, width: width, height: height)
                }
                guard let raster = PanelRaster.rgb(image) else {
                    throw PanelCaptureError.noPixelBuffer
                }
                let canvas = PanelImage.compose(
                    content: raster.pixels,
                    width: raster.width, height: raster.height,
                    // Panel == content: the corner rounding is the only thing compose adds here.
                    panelWidth: raster.width,
                    panelHeight: raster.height,
                    originX: 0,
                    originY: 0,
                    // No rounded corners ("把圆角边框去掉吧，我记得加之前是正常的"). A cut corner is a
                    // *hole* in the picture: the terminal puts its own background there (Rex: black),
                    // so a rounded picture reads as a frame around a smaller picture instead of as
                    // the desktop itself. It is also the only alpha in the wall's images, and alpha
                    // is the property a terminal is most likely to handle differently from RGB.
                    cornerRadius: 0)
                guard canvas.count == raster.width * raster.height * 4 else {
                    throw PanelCaptureError.noPixelBuffer
                }
                pictures.append(Picture(panel: panel, pixels: canvas,
                                        width: raster.width, height: raster.height))
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
        return (pictures, failures)
    }
}
