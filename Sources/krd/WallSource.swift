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
        let entries = screens.map { screen -> (name: String, minX: Double, main: Bool) in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) }
            return (name: screen.localizedName,
                    minX: screen.frame.minX,
                    main: id.map { CGDisplayIsMain($0) != 0 } ?? false)
        }
        return ordered(entries).map { index in
            let screen = screens[index]
            return WallDisplay(name: entries[index].name,
                               width: points(screen.frame.size.width),
                               height: points(screen.frame.size.height),
                               main: entries[index].main)
        }
    }

    /// Everything one repaint needs, re-read as one unit so the painter can compare it against the
    /// previous draw and emit nothing when it did not change.
    static func model() -> WallModel {
        WallModel(displays: displays(), windows: windows())
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
    /// and this runs on the 1 s timer, where a trap leaves the terminal in the alternate screen.
    private static func points(_ value: CGFloat) -> Int {
        guard value.isFinite, value >= 0 else { return 0 }
        return Int(min(Double(value), 1e9).rounded())
    }
}
