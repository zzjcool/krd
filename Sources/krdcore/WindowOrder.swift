/// `CGWindowListCopyWindowInfo` dictionaries → the windows a card wall should show.
///
/// Two facts about that list are the whole reason this is a tested function instead of a `filter`
/// at the call site, and neither is visible in the type (`[[String: Any]]`):
///
/// 1. **The system injects layer-0 overlays that pair with real windows.** On a real machine
///    `WindowManager` (pid 93439) emits one `Gesture Blocking Overlay` per covered window, at
///    layer 0, with *exactly the same bounds*, interleaved one-for-one with the window it covers
///    (`94251`, 192x177 at -183,-831, is immediately followed by the `Google Chrome` window
///    `124586`, same rectangle), plus nine 66x82 `App Icon Window` entries that survive any size
///    filter. Both a layer filter and a size filter *keep* them; "the owner is a regular app
///    (has a Dock icon)" keeps exactly the real windows. So the pid rule below is the **primary**
///    rule and the owner-name blocklist is only belt and braces.
///    `Tests/krdcoreTests/Fixtures/cgwindowlist-host.json` is that list unedited — 43 entries,
///    37 at layer 0, 22 of them owned by `WindowManager` — and the suite pins the 15 survivors.
/// 2. **The order is z order: front to back, i.e. MRU-ish but not strict.** A window that is
///    raised without being activated also moves up, so what a caller gets is a free approximation
///    of "recently used" (design §3), not an exact history. Exactness would need its own
///    bookkeeping, and krd has no AppKit run loop to hear `didActivateApplicationNotification`
///    from. That is why the order is handed back exactly as given: no sorting, no dedup by pid —
///    one app may legitimately own several cards (the host list has three `企业微信` windows and
///    they are three windows).
///
/// Platform-neutral by contract (issue #21): the currency is plain Swift plus the dictionary shape
/// `JSONSerialization` also produces, so the suite drives it from fixtures with no window server
/// involved. Every cast is conditional and every number goes through a checked parse, so a
/// missing, truncated or outright hostile dictionary drops that one window and never traps.
public enum WindowOrder {
    /// Owners the system puts on the list with windows of their own and nothing to show. Matched
    /// exactly, not by prefix or substring: these are `kCGWindowOwnerName` values, not a pattern,
    /// and a fuzzy match would silently hide any future app whose name contains one of them.
    public static let systemOwners: Set<String> = [
        "WindowManager", "Dock", "Window Server", "Control Center", "Notification Center",
    ]

    /// Below this a card would be an unreadable thumbnail, and it is also the floor that catches
    /// the 1x1 `WindowManager` probe entry in the real list (`109628`). The 66x82 overlays are
    /// above the floor on purpose: they must be dropped by pid, so the floor cannot be doing the
    /// work the pid rule is there for.
    public static let minimumExtent: Double = 40

    /// The windows from `dictionaries` that are worth a card, in the order given.
    ///
    /// - Parameters:
    ///   - dictionaries: `[[String: Any]]` as returned by `CGWindowListCopyWindowInfo`, or the
    ///     same list after a round trip through JSON.
    ///   - regularPIDs: pids of the apps with a Dock icon (in `krd`: `NSWorkspace`'s running
    ///     applications with `activationPolicy == .regular`). This — not the layer and not the
    ///     size — is what separates real windows from the system's own layer-0 overlays.
    public static func recent(_ dictionaries: [[String: Any]],
                              regularPIDs: Set<Int32>) -> [OrderedWindow] {
        // compactMap, not a loop with `append`: the one property of this function that is easy to
        // lose later is that the order comes out the way it went in.
        dictionaries.compactMap { window($0, regularPIDs: regularPIDs) }
    }

    /// The rules in order; the first failing one drops the window. Numbers are in the contract's
    /// order rather than in "cheapest first" order so a reader can check this against the design.
    private static func window(_ dictionary: [String: Any],
                               regularPIDs: Set<Int32>) -> OrderedWindow? {
        // 1. Layer 0 only: everything above is a panel/menu of the system's, everything below is
        //    the desktop or a notification. A missing key is not "probably 0" — drop it.
        guard int(dictionary["kCGWindowLayer"]) == 0 else { return nil }

        // 2. The primary rule. `WindowManager`'s overlays are regular-looking apps with layer-0
        //    windows, so this is the only rule that separates them from real windows.
        guard let pid = int32(dictionary["kCGWindowOwnerPID"]), regularPIDs.contains(pid) else {
            return nil
        }

        // 3. Belt and braces: never *keep* what the name says is the system, whatever the pid set
        //    claims. Correctness does not rest on this (the host fixture asserts that adding
        //    `WindowManager`'s pid to `regularPIDs` changes nothing).
        let app = dictionary["kCGWindowOwnerName"] as? String
        if let app = app, systemOwners.contains(app) { return nil }

        // 4. The rectangle, as four numbers. Non-finite values (NaN/infinity can be produced by a
        //    broken window and by a hostile fixture) would poison every comparison downstream.
        guard let bounds = rect(dictionary["kCGWindowBounds"]),
              bounds.width >= minimumExtent, bounds.height >= minimumExtent else { return nil }

        // 5. The id the capture path will need. Out of range (`UInt32`) is the same as missing:
        //    there is no window to point at.
        guard let id = uint32(dictionary["kCGWindowNumber"]) else { return nil }

        return OrderedWindow(windowID: id, pid: pid,
                             app: app ?? "",
                             title: title(dictionary["kCGWindowName"]),
                             bounds: bounds)
    }

    /// `nil` when the window has nothing to print, and never `""`.
    ///
    /// An empty name means "nothing to show" — the cards must fall back to "window N" rather than
    /// render a blank second line. Real data has both shapes: the host list has four windows with
    /// `""` (`企业微信` x2, `iOA`, `YunDun` — those apps hide the title, not the window) and one
    /// with an `NSNull`. A *real* title is returned untrimmed: only the blank test trims.
    private static func title(_ value: Any?) -> String? {
        guard let string = value as? String, !string.allSatisfy({ $0.isWhitespace }) else {
            return nil
        }
        return string
    }

    /// `kCGWindowBounds` → four numbers, or `nil` if any of them is missing or not a number.
    private static func rect(_ value: Any?) -> CGRectCompat? {
        guard let dictionary = value as? [String: Any],
              let x = double(dictionary["X"]), let y = double(dictionary["Y"]),
              let width = double(dictionary["Width"]), let height = double(dictionary["Height"])
        else { return nil }
        return CGRectCompat(x: x, y: y, width: width, height: height)
    }

    /// Checked numeric parse. These values arrive as `NSNumber`: bridged from CoreGraphics in
    /// `krd`, bridged from `JSONSerialization` in the tests. `as?` performs that bridge for free,
    /// which is why this file needs no `NSNumber` cast and no CoreGraphics import — the price is
    /// that each shape has to be asked for explicitly.
    private static func double(_ value: Any?) -> Double? {
        // Int first: an integral `NSNumber` satisfies both casts, and an integer is the shape the
        // window list actually hands out for these four keys.
        if let int = value as? Int { return Double(int) }
        // isFinite, not `!isNaN`: an infinite width breaks the layout arithmetic just as quietly.
        if let double = value as? Double, double.isFinite { return double }
        return nil
    }

    /// An integer-valued parse that also accepts the `Double` shape, because "numeric" in the
    /// window list is not guaranteed to be `Int` (a bridged 0.0 is still layer 0).
    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double, double.isFinite, double == double.rounded() {
            return Int(exactly: double)
        }
        return nil
    }

    private static func int32(_ value: Any?) -> Int32? {
        if let int = value as? Int32 { return int }
        return int(value).flatMap { Int32(exactly: $0) }
    }

    private static func uint32(_ value: Any?) -> UInt32? {
        if let int = value as? UInt32 { return int }
        return int(value).flatMap { UInt32(exactly: $0) }
    }
}

/// A rectangle in the coordinate space of `kCGWindowBounds`: points, top-left origin, y growing
/// down, origins that may be negative or past the first display.
///
/// Four plain numbers rather than `CGRect`: `krdcore` must compile and be tested without
/// CoreGraphics or AppKit (issue #21), and nothing on the wall path needs more than the numbers
/// (the capture path converts them itself, in `krd`).
public struct CGRectCompat: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One window worth a card, carrying exactly what a card prints and what a click has to carry.
public struct OrderedWindow: Equatable {
    /// `kCGWindowNumber` — stable for the window's lifetime, which is what a later capture of that
    /// one window addresses.
    public let windowID: UInt32
    public let pid: Int32
    /// `kCGWindowOwnerName`; `""` when the list has no name for it (the pid was regular, so this
    /// is a real app whose owner name is missing — dropping it would lose a real window).
    public let app: String
    /// The window title, or `nil` when there is nothing to print (see `WindowOrder.recent`).
    public let title: String?
    public let bounds: CGRectCompat

    public init(windowID: UInt32, pid: Int32, app: String, title: String?, bounds: CGRectCompat) {
        self.windowID = windowID
        self.pid = pid
        self.app = app
        self.title = title
        self.bounds = bounds
    }
}
