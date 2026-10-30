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
        /// Exactly `panel.pixelWidth x panel.pixelHeight` **RGBA**: the picture, with the bars
        /// left transparent so the wall's own background shows through (design §6.6).
        let pixels: [UInt8]
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
                let canvas = PanelImage.compose(content: raster.pixels,
                                                width: raster.width, height: raster.height,
                                                panelWidth: panel.pixelWidth,
                                                panelHeight: panel.pixelHeight,
                                                originX: panel.fit.originX,
                                                originY: panel.fit.originY)
                guard canvas.count == panel.pixelWidth * panel.pixelHeight * 4 else {
                    throw PanelCaptureError.noPixelBuffer
                }
                pictures.append(Picture(panel: panel, pixels: canvas))
            } catch {
                failures[panel.slot] = PanelCapture.classify(error)
            }
        }
        return (pictures, failures)
    }
}
