import Foundation
import CoreGraphics
import Accelerate

/// A captured picture in the shape the encoder wants: plain RGB, one contiguous buffer, rows
/// top-down.
///
/// WHY this file exists at all: the mirror path gets BGRA from a `CVPixelBuffer` and converts with
/// vImage (Capture.swift); a panel gets a `CGImage` from `SCScreenshotManager` instead, and handing
/// that to the same encoder means going through a bitmap context first. Two conversions, one
/// output format, so a panel and a tile are indistinguishable downstream.
enum PanelRaster {
    /// Draw `image` into an RGB buffer.
    ///
    /// The row reversal is not optional: `CGContext` puts the origin at the bottom-left, so a
    /// context drawn into and read back row 0..h-1 would show the picture upside down. That is
    /// invisible in a solid-colour test and obvious the first time a window with text is captured,
    /// which is why it is done here, once, and not left to a caller to remember.
    /// - Parameters:
    ///   - width, height: the size the picture must end up at. `nil` keeps the capture's own size.
    ///
    /// WHY a box that may differ from the capture: `SCScreenshotManager` never *invents* pixels - ask
    /// it for a 2431-pixel-wide display shot of a 1920-pixel-wide display and it answers 1920, scaled
    /// down - and a terminal that draws an image at its own pixel size (Rex does: one image pixel per
    /// device pixel, whatever `c`/`r` say) then fills only part of the picture's cells and leaves the
    /// rest of the band black. Measured on the VM's 1920x1200 display in a 143x46-cell stage: the
    /// capture came back at the display's own width and the desktop sat in the top-left of its box
    /// with black to the right and below. Scaling here costs one resample of a screenshot that was
    /// going to be resampled by the terminal anyway, and it makes the picture's pixels equal its
    /// cells' pixels in *every* transport.
    static func rgb(_ image: CGImage, width: Int? = nil, height: Int? = nil)
        -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = width ?? image.width, h = height ?? image.height
        guard w > 1, h > 1, image.width > 1, image.height > 1 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            // Same size -> no interpolation: resampling would only blur what ScreenCaptureKit just
            // produced. Different size -> the capture is the source's own pixels and the terminal
            // will not scale, so this is the only place the picture can reach its cells.
            ctx.interpolationQuality = (w == image.width && h == image.height) ? .none : .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        let converted = rgba.withUnsafeBytes { src -> Bool in
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress),
                                       height: vImagePixelCount(h), width: vImagePixelCount(w),
                                       rowBytes: w * 4)
            return rgb.withUnsafeMutableBytes { dst -> Bool in
                var out = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h),
                                        width: vImagePixelCount(w), rowBytes: w * 3)
                return vImageConvert_RGBA8888toRGB888(&source, &out, vImage_Flags(kvImageNoFlags))
                    == kvImageNoError
            }
        }
        guard converted else { return nil }
        // No flip. `CGContext.draw` into a byte buffer already lands the picture's top row in the
        // buffer's first row (checked against a coloured-corner image: red/green/blue on top), so
        // flipping here would show the wall upside down — which is exactly what the first live run
        // did. Kept as a comment because "the origin is bottom-left" makes the opposite look right.
        return (rgb, w, h)
    }
}
