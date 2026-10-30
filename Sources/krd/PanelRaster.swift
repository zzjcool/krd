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
    static func rgb(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        guard w > 1, h > 1 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            // The picture is already at its final size (the capture was asked for it), so no
            // interpolation: resampling here would only blur what ScreenCaptureKit just produced.
            ctx.interpolationQuality = .none
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
