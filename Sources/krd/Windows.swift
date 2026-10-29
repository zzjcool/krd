import CoreGraphics

/// Recognising a backdrop, i.e. the desktop layer rather than a window with content.
///
/// `--window` builds an `SCContentFilter` for whatever it matched. For the desktop entry in
/// `--list` (Finder with an empty title, or the per-display "Backstop") that filter returns the
/// uncomposited backdrop layer: an all-black frame with exit status 0 and nothing saying why
/// (issue #24 — 146 846 of 146 880 pixels were `(0,0,0)`).
///
/// Pure on purpose: the decision is a comparison on numbers the system hands us, so it is tested
/// with plain rectangles instead of a window server.
enum WindowPick {
    /// The desktop-icon level. Everything a user can see, click or front is at or above it:
    /// normal windows are 0, the menu bar 24, login window UI ~2000, the screen-share shield at the
    /// very top. Below it live the desktop picture, its per-display backstop, and the wallpaper
    /// windows — measured on macOS 26 as -2147483603 (Finder's desktop) down to -2147483626
    /// (backstop). Notification-centre widgets are at -2147483601, above this line, and their frames
    /// are small anyway.
    static let backdropLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

    /// The display bounds a backdrop window covers, or nil when the window is a normal one.
    ///
    /// Both halves are required, so the test stays conservative: a layer below the desktop, *and*
    /// (nearly) a whole display's area. The 90 % tolerance is for the desktop window itself, which
    /// is inset by the menu bar and the Dock (1418x2518 of a 1440x2560 display on the machine this
    /// was written on).
    static func backdrop(layer: Int, frame: CGRect, displays: [CGRect]) -> CGRect? {
        guard layer <= backdropLayer else { return nil }
        for bounds in displays {
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let cover = frame.intersection(bounds)
            guard !cover.isNull, !cover.isEmpty else { continue }
            if cover.width * cover.height >= 0.9 * bounds.width * bounds.height { return bounds }
        }
        return nil
    }

    /// Active display bounds in CoreGraphics space, without ScreenCaptureKit.
    ///
    /// `SCShareableContent.displays` can come back **empty** while windows are still listed (that is
    /// what this machine does on macOS 26), and `CGGetActiveDisplayList` can be empty too while the
    /// session's displays are merely online, so this asks for *online* displays. Indices here are
    /// advisory only: they do not necessarily order like `--display`'s do, which is why the caller
    /// prefers the shareable list when it has one.
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}
