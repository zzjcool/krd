import Foundation
import CoreGraphics
import ScreenCaptureKit

/// Why a panel has no picture. The wall draws a mask for every one of these (design §6.6): a card
/// must never show a stale picture of a window that is gone, and a denied capture is not an error
/// the reader can act on mid-screen.
enum PanelCaptureError: Error, Equatable {
    case windowGone        // the window id no longer resolves (closed, or minimised away)
    case denied            // Screen Recording refused (SCStreamErrorUserDeclined / missing entitlement)
    case noPixelBuffer     // the stream produced nothing usable
    case failed(String)    // anything else, message only
}

/// One picture of one panel, once — the landing screen's whole capture path.
///
/// `Capture.swift` is not touched from here on purpose. It owns the mirror's single long-lived
/// `SCStream`, and a stream's frame size is fixed when it starts, while the wall's panels differ in
/// size; so each panel is one `SCScreenshotManager` call instead of a stream (P0, measured
/// 2026-10-30 in the tart VM: a 1920×1200 display in 25.9 ms, windows in 18.3–28.7 ms, a whole
/// wall's four panels in 92.4 ms — once per change, not per frame). Nothing here keeps state
/// between calls, so there is no lifecycle to get wrong and no stream to restart.
struct PanelCapture {
    /// One picture of exactly one window, scaled by ScreenCaptureKit to the size asked for.
    /// The caller asks in the *content's* aspect (SCK scales to fit, anchored top-left, black
    /// padding otherwise - measured 2026-10-30), so no cropping happens here.
    static func window(id: CGWindowID, width: Int, height: Int) async throws -> CGImage {
        try await capture(width: width, height: height) { content in
            // No fallback to another window: the picture on a card is that window or a mask
            // (§6.6). Substituting a neighbour would be a wrong picture, which is worse than none.
            guard let window = find(id, in: content.windows, id: \.windowID) else {
                throw PanelCaptureError.windowGone
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    /// The same for a display.
    static func display(id: CGDirectDisplayID, width: Int, height: Int) async throws -> CGImage {
        try await capture(width: width, height: height) { content in
            // An id that is not in the list is a display that was unplugged or is asleep. There is
            // no `.displayGone` because a display is re-enumerated before it can be drawn at all:
            // the wall never holds a card for one it cannot find, so this is an id from a stale
            // model, not a panel that lost its picture.
            guard let display = find(id, in: content.displays, id: \.displayID) else {
                throw PanelCaptureError.failed("display \(id) is not in the shareable list")
            }
            return SCContentFilter(display: display, excludingWindows: [])
        }
    }

    /// First item whose id matches, or `nil`.
    ///
    /// `SCWindow` and `SCDisplay` have no public initialiser, so the rule itself is generic and
    /// `PanelCaptureTests` drives it with plain structs. What has to hold is that the id decides,
    /// the *first* duplicate wins (the list is already ordered front to back, so the first one is
    /// the window the reader pointed at), and a missing id never becomes a neighbour.
    static func find<T>(_ id: UInt32, in items: [T], id idOf: (T) -> UInt32) -> T? {
        for item in items where idOf(item) == id { return item }
        return nil
    }

    /// Enumerate, filter, shoot. Only the filter differs between a window and a display, so both
    /// callers share this rather than repeating the configuration and the error policy.
    private static func capture(width: Int, height: Int,
                                filter: (SCShareableContent) throws -> SCContentFilter) async throws -> CGImage {
        do {
            // The same list the wall's cards come from, for the same reason: a window that is not
            // on screen is not a card, so it is not captured either.
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                              onScreenWindowsOnly: true)
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = false
            // The scale is deliberately left alone: `pointPixelScale` would turn `width`/`height`
            // from the picture's size into a hint, and the measured fit (aspect kept, anchored
            // top-left, black padding) is exactly what the caller already compensated for.

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter(content),
                                                                   configuration: configuration)
            // The async import hands back a non-optional image, so the one unusable picture left
            // is an empty one; tiles and the encoder assume at least one pixel and would trap.
            guard image.width > 0, image.height > 0 else { throw PanelCaptureError.noPixelBuffer }
            return image
        } catch {
            throw classify(error)
        }
    }

    /// One policy for all four failure modes, so a caller only ever sees `PanelCaptureError` and a
    /// panel's mask never depends on which of the calls happened to fail.
    ///
    /// The numbers are `SCStreamErrorDomain`'s (`SCError.h`); anything else — a `CGError`, an
    /// error we threw ourselves — keeps its message and loses only its type.
    static func classify(_ error: Error) -> PanelCaptureError {
        // Already ours: the catch in `capture` re-classifies, and a test may hand one straight in.
        if let known = error as? PanelCaptureError { return known }
        let ns = error as NSError
        // The code alone proves nothing: `-3801` in another domain is some other refusal.
        guard ns.domain == SCStreamErrorDomain else { return .failed(ns.localizedDescription) }
        switch ns.code {
        case -3801:
            // SCStreamErrorUserDeclined: the TCC answer, or a picker the user cancelled. No retry
            // will help until the reader opens System Settings, which is not this function's news.
            return .denied
        case -3803:
            // SCStreamErrorMissingEntitlements: the same answer with no dialog in between.
            return .denied
        case -3813:
            // SCStreamErrorNoWindowList: the window left between enumeration and the shot — the
            // one failure the capture call itself reports as "gone" rather than as a policy.
            return .windowGone
        default:
            // -3802 / -3804 (failed to start, connection invalid) land here: a transient fault is
            // worth a retry on the next tick, so it must not be mistaken for a permission answer.
            return .failed(ns.localizedDescription)
        }
    }
}
