import AppKit
import CoreGraphics
import Foundation
import krdcore

/// What the wall shows, read from the window server and from `NSScreen`: the enumeration bridge
/// between AppKit/CoreGraphics and the pure `krdcore` types the painter draws.
///
/// ## Why the wall never asks for a grant
///
/// `CGWindowListCopyWindowInfo` needs no Screen Recording grant for any field `WindowOrder` reads:
/// owner name, owner pid, layer, bounds and the window number are all in the public list. Only
/// `kCGWindowName` — the title — is withheld without the grant, and a missing title is a *normal*
/// wall, not a degraded one: `WallCanvas` draws `window N` for it (design §3). So `--wall` must
/// never touch `SCShareableContent`, which is the call that throws when the grant is missing
/// (`main.swift` reaches it for every mirroring path); a wall-only session has to start and render
/// with Screen Recording denied. The one seam that keeps that true is the branch in
/// `Desk.run()`, which is placed strictly before `SCShareableContent.excludingDesktopWindows`.
///
/// ## Why the ordering rule is a pure function here
///
/// Which display is "first" is a policy (`main` first, then left to right), and it decides which
/// display the stage shows and which index a click's `enterStage` payload means. Screen geometry
/// cannot be faked in a test, so the policy is lifted out of `displays()` into `ordered(_:)`, which
/// takes plain tuples and returns indices: no `NSScreen`, no `CGDirectDisplayID`, no window server.
enum WallSource {
    /// The apps with a Dock icon. This — not the window layer — is what separates a real window
    /// from the system's layer-0 overlays (`WindowManager`, the `Dock`, the menu bar extras).
    static func regularPIDs() -> Set<Int32> {
        var pids = Set<Int32>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            pids.insert(app.processIdentifier)
        }
        return pids
    }

    /// The on-screen windows, front to back, filtered and ordered by `WindowOrder`.
    ///
    /// `optionOnScreenOnly` + `excludeDesktopElements` is the cheapest list that can contain what
    /// a card shows (a minimised or fully occluded window is not "most recently used"); the pid
    /// rule inside `WindowOrder` is what actually makes the list cards.
    static func windows() -> [OrderedWindow] {
        let dictionaries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] ?? []
        return WindowOrder.recent(dictionaries, regularPIDs: regularPIDs())
    }

    /// The displays in the order the wall draws them, sized in points (what the caption prints and
    /// what a mirror would be described in — pixels would only say how dense the panel is).
    static func displays() -> [WallDisplay] {
        let screens = NSScreen.screens
        // Kept beside `entries` rather than inside it: the ordering policy takes the plain tuple,
        // and its test drives it with hand-written values that have no display id to give.
        let ids = screens.map { screen -> UInt32 in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) } ?? 0
        }
        let entries = screens.enumerated().map { index, screen -> (name: String, minX: Double, main: Bool) in
            (name: screen.localizedName,
             minX: screen.frame.minX,
             main: ids[index] != 0 && CGDisplayIsMain(ids[index]) != 0)
        }
        return ordered(entries).map { index in
            let screen = screens[index]
            return WallDisplay(name: entries[index].name,
                               width: points(screen.frame.size.width),
                               height: points(screen.frame.size.height),
                               id: ids[index],
                               main: entries[index].main)
        }
    }

    /// How long the wall may go stale before its own poll looks again (issue #169 review).
    ///
    /// This is the hard upper bound on every staleness case the fingerprint can see, and the case it
    /// exists for is the one AppKit never announces: a window that closes or opens inside the app
    /// that is already frontmost. 2.0 s rather than 1 s because the poll's cost is now the bound's
    /// cost — one `fingerprint()` per interval instead of the per-second enumeration of #141.
    static let pollInterval: TimeInterval = 2.0

    /// A four-scalar summary of the world, strictly less work than `model()` on the same list
    /// (issue #169 review): the poll runs it forever, so it must not pay for the enumeration it is
    /// there to avoid.
    ///
    /// Which is why nothing here goes through `windows()`: that bridges the window list into
    /// `[[String: Any]]` (a dictionary per window) and then applies `WindowOrder`'s bounds and name
    /// rules. This walks the same `CFArray` as CF objects with `CFArrayGetValueAtIndex` /
    /// `CFDictionaryGetValue` and reads three keys per window — layer, owner pid, window number — then
    /// keeps only the windows `WindowOrder` would keep at its primary rule: layer 0, owned by a
    /// regular app. The count and the id sum are both kept because they fail differently: window
    /// numbers are never reused, so a close plus an open moves `ids` where a bare count would cancel.
    static func fingerprint() -> WallFingerprint {
        let pids = cachedRegularPIDs()
        var windows = 0
        var ids = 0
        // `CFArray`, not `as? [[String: Any]]`: bridging is the part of the cost this drops (the CF
        // walk measured ~2 µs against ~70 µs for the bridge, on the same 30-window list).
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) {
            // `max(0, _)`: a negative count would trap in the range, and this list comes from
            // another process.
            let count = max(0, CFArrayGetCount(list))
            for index in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
                let window = Unmanaged<CFDictionary>.fromOpaque(raw).takeUnretainedValue()
                guard integer(window, kCGWindowLayer) == 0,
                      let pid = integer(window, kCGWindowOwnerPID),
                      pids.contains(Int32(truncatingIfNeeded: pid)) else { continue }
                windows += 1
                // Sum, not set: "one closed while another opened" has to move something, and
                // `&+=` because the numbers are the window server's, not ours.
                ids &+= integer(window, kCGWindowNumber) ?? 0
            }
        }
        return WallFingerprint(windows: windows,
                               ids: ids,
                               frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                               displays: activeDisplayIDs())
    }

    /// One integer-valued key of a window dictionary, or `nil` when the key is missing or holds
    /// something that is not a number.
    ///
    /// The list is produced by another process, so nothing here may assume a type: a `String` or a
    /// `CFBoolean` under `kCGWindowLayer` must become `nil`, not a `takeUnretainedValue()` on the
    /// wrong CF class (undefined behaviour) and not an `as!` (a trap on the wall's timer path, where
    /// it leaves the terminal in the alternate screen).
    private static func integer(_ window: CFDictionary, _ key: CFString) -> Int? {
        guard let raw = CFDictionaryGetValue(window, Unmanaged.passUnretained(key).toOpaque()) else {
            return nil
        }
        let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(object) == CFNumberGetTypeID() else { return nil }
        var value: Int64 = 0
        guard CFNumberGetValue(Unmanaged<CFNumber>.fromOpaque(raw).takeUnretainedValue(),
                               .sInt64Type, &value) else { return nil }
        return Int(truncatingIfNeeded: value)
    }

    /// The active displays as CoreGraphics sees them, sorted so that a reordered list is not a
    /// change.
    ///
    /// Deliberately not `NSScreen.screens` (what `displays()` reads): the poll must stay cheap, and
    /// the id set is the part of a plug/unplug/rearrange that moves first anyway.
    ///
    /// **Cached**, because this is the poll's most expensive part: `CGGetActiveDisplayList` measured
    /// 1.6 ms per call on this machine, which at one call per 2 s would be 0.8 ms/s — two thirds of
    /// the very cost issue #141 removed. The set only moves on
    /// `didChangeScreenParametersNotification`, which `WallWatch` already observes, so
    /// `invalidateFingerprint()` on that notification makes the cache exact rather than merely fresh.
    private static func activeDisplayIDs() -> [UInt32] {
        cacheLock.lock()
        let cached = cachedDisplays
        cacheLock.unlock()
        if let cached { return cached }
        var count: UInt32 = 0
        // A cap as well as the `> 0`: a hostile count must not decide the size of an allocation.
        var ids: [UInt32] = []
        if CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 {
            var buffer = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetActiveDisplayList(count, &buffer, &count) == .success {
                // The second call rewrites `count` to the number it actually filled in.
                ids = Array(buffer.prefix(min(Int(count), buffer.count))).sorted()
            }
        }
        cacheLock.lock()
        cachedDisplays = ids
        cacheLock.unlock()
        return ids
    }

    /// The pieces of the fingerprint that cannot move without a notification we already hear: the
    /// regular-pid set (launch/terminate) and the display ids (screen parameters). Both are cached
    /// and dropped by `invalidateFingerprint()`, so the poll itself costs one window-list walk.
    private static let cacheLock = NSLock()
    private static var cachedPIDs: Set<Int32>?
    private static var cachedDisplays: [UInt32]?

    /// Drop the caches whose truth a notification just moved. Called from `WallWatch`; exact, not
    /// periodic — a launch is the only way the pid set can change, and `WallWatch` hears every one.
    static func invalidateFingerprint() {
        cacheLock.lock()
        cachedPIDs = nil
        cachedDisplays = nil
        cacheLock.unlock()
    }

    /// `regularPIDs()` once per notification interval rather than once per poll: the same argument as
    /// the display cache, and it is 0.23 ms of the poll's cost.
    private static func cachedRegularPIDs() -> Set<Int32> {
        cacheLock.lock()
        let cached = cachedPIDs
        cacheLock.unlock()
        if let cached { return cached }
        let pids = regularPIDs()
        cacheLock.lock()
        cachedPIDs = pids
        cacheLock.unlock()
        return pids
    }

    /// Everything one repaint needs, re-read as one unit so the painter can compare it against the
    /// previous draw and emit nothing when it did not change.
    static func model() -> WallModel {
        WallModel(displays: displays(), windows: windows())
    }

    /// A model that does not come from the window server (`--demo`).
    ///
    /// Why the demo also replaces the *list* of sources: "we are both looking at the same thing" is
    /// the whole value of a joint debug session. With the real window list the demo's pictures would
    /// have whatever aspects the reader happens to have open, so the same pane size would produce a
    /// different layout on two machines and neither could reproduce the other's screen. These four
    /// windows are chosen to exercise the fit: wider than the card, square, taller than the card, and
    /// an extreme 21:9.
    static func demoModel() -> WallModel {
        WallModel(
            displays: [WallDisplay(name: "Demo Display", width: 2560, height: 1600,
                                   id: 1, main: true)],
            windows: [
                OrderedWindow(windowID: 1, pid: 1, app: "Demo", title: "16:9 window",
                              bounds: CGRectCompat(x: 0, y: 0, width: 1920, height: 1080)),
                OrderedWindow(windowID: 2, pid: 1, app: "Demo", title: "4:3 window",
                              bounds: CGRectCompat(x: 0, y: 0, width: 1600, height: 1200)),
                OrderedWindow(windowID: 3, pid: 1, app: "Demo", title: "square window",
                              bounds: CGRectCompat(x: 0, y: 0, width: 1200, height: 1200)),
                OrderedWindow(windowID: 4, pid: 1, app: "Demo", title: "21:9 window",
                              bounds: CGRectCompat(x: 0, y: 0, width: 2520, height: 1080))
            ]
        )
    }

    /// The display order: the menu-bar display first, then left to right by `frame.minX`.
    ///
    /// The index tie break is explicit rather than relying on `sorted` being stable: two screens
    /// can report the same `minX` (mirrored, or side by side from a rotated frame), and a wall that
    /// reshuffles its own stage when nothing changed would be a bug nobody can reproduce.
    /// A non-finite `minX` is not a real frame; it sorts last instead of making the comparator
    /// inconsistent (which would leave the order up to the sort algorithm).
    static func ordered(_ entries: [(name: String, minX: Double, main: Bool)]) -> [Int] {
        entries.indices.sorted { a, b in
            let left = entries[a], right = entries[b]
            if left.main != right.main { return left.main }
            let lx = left.minX.isFinite ? left.minX : .infinity
            let rx = right.minX.isFinite ? right.minX : .infinity
            if lx != rx { return lx < rx }
            return a < b
        }
    }

    /// Screen frames are points and come from another process: a NaN would trap in `Int(_:)`,
    /// and this runs on a wall trigger (a notification, a resize), where a trap leaves the terminal
    /// in the alternate screen.
    private static func points(_ value: CGFloat) -> Int {
        guard value.isFinite, value >= 0 else { return 0 }
        return Int(min(Double(value), 1e9).rounded())
    }
}
