import CoreGraphics
import Foundation
import krdcore

/// Turns a plan into pixels: one picture per panel, with the bars already painted.
///
/// What this is *not*: a frame loop. The wall captures when the desk changes (the 1 s tick decides
/// that), so there is no dedupe, no cache and no stream to keep alive — measured at 92 ms for a
/// whole wall's four panels (design §12, P0).
enum WallPictures {
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
                let image: CGImage
                switch panel.source {
                case let .display(id):
                    image = try await PanelCapture.display(id: id,
                                                           width: panel.fit.contentWidth,
                                                           height: panel.fit.contentHeight)
                case let .window(id):
                    image = try await PanelCapture.window(id: id,
                                                          width: panel.fit.contentWidth,
                                                          height: panel.fit.contentHeight)
                }
                guard let raster = PanelRaster.rgb(image) else {
                    throw PanelCaptureError.noPixelBuffer
                }
                // The stage is the desktop itself. The mirror draws it square and edge to edge, and
                // rounding it here made the wall's display look like "a different frame" around the
                // desktop (the report that produced this) - the same pixels, drawn two ways on two
                // screens is exactly what a reader notices. Cards keep their rounding: they read as
                // windows lying on the wall, which the stage never was.
                var radius = 0
                if case .window = panel.source {
                    // The capture is the size it will be drawn at, so the radius is in the same
                    // pixels and does not change when the pane is resized.
                    radius = PanelImage.cornerRadius(width: raster.width, height: raster.height)
                }
                let canvas = PanelImage.compose(
                    content: raster.pixels,
                    width: raster.width, height: raster.height,
                    // Panel == content: the corner rounding is the only thing compose adds here.
                    panelWidth: raster.width,
                    panelHeight: raster.height,
                    originX: 0,
                    originY: 0,
                    cornerRadius: radius)
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
