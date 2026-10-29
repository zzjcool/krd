// Which display a session captures, and why.
//
// Capture is started once against one display, so the interesting question is what to do when
// the set of displays changes underneath: a monitor is plugged in, unplugged, mirrored, rotated,
// or the lid closes and fires the notification two or three times in a row. The answer has to be
// decided in one place, be the same every time, and be sayable in one line of `--debug` output --
// so it is a pure function here, and `Desk` only does the plumbing around it.

import CoreGraphics
import Foundation

/// A display as the picker sees it: ScreenCaptureKit's `SCDisplay.displayID` and its bounds.
struct DisplayBox: Equatable {
    var id: CGDirectDisplayID
    var bounds: CGRect
}

/// One decision, with the sentence that explains it.
struct DisplayChoice: Equatable {
    var display: DisplayBox
    /// `--debug` prints this verbatim, so it has to make sense on its own.
    var reason: String
    /// The session had been on another display and that one is gone. The user did not ask to
    /// move, so this is worth a line even without `--debug`.
    var fellBack: Bool
}

enum DisplayPick {
    /// Which display to capture now.
    ///
    /// - `requested`: the `--display <i>` index, which indexes the *current* list (that is what
    ///   `--list` printed). It wins when it is in range, because the user pinned it.
    /// - `tracked`: the display the session is on. Kept as long as it exists, even when the
    ///   pointer wandered onto another screen -- that is the difference between "mirror my
    ///   screen" and "follow my mouse".
    /// - `pointer`: where the pointer is, used when there is nothing to keep.
    ///
    /// Returns nil only when macOS reports no displays at all, which the caller reports as an
    /// environment failure rather than guessing a rectangle.
    static func choose(requested: Int?, tracked: CGDirectDisplayID?,
                       displays: [DisplayBox], pointer: CGPoint,
                       main: CGDirectDisplayID) -> DisplayChoice? {
        guard !displays.isEmpty else { return nil }
        let had = tracked.flatMap { id in displays.first { $0.id == id } }
        let count = displays.count

        if let requested, displays.indices.contains(requested) {
            let display = displays[requested]
            if let had, had.id == display.id {
                return DisplayChoice(display: display, reason: "display \(requested) (the one already mirrored)", fellBack: false)
            }
            let why = count == 1 ? "display \(requested) (the only one)" : "display \(requested) of \(count)"
            return DisplayChoice(display: display, reason: why, fellBack: had == nil && tracked != nil)
        }

        let requestedNote = requested.map { index in
            " (--display \(index) is out of range: \(count) display(s) now)"
        } ?? ""

        if let had {
            return DisplayChoice(display: had, reason: "still on display \(had.id)\(requestedNote)", fellBack: false)
        }

        if let under = displays.first(where: { $0.bounds.contains(pointer) }) {
            let reason = tracked == nil
                ? "pointer is on display \(under.id)"
                : "display \(tracked!) is gone; following the pointer to display \(under.id)"
            return DisplayChoice(display: under, reason: reason + requestedNote, fellBack: tracked != nil)
        }

        if let mainDisplay = displays.first(where: { $0.id == main }) {
            return DisplayChoice(display: mainDisplay,
                                 reason: "nothing under the pointer, using the main display \(mainDisplay.id)"
                                     + requestedNote,
                                 fellBack: tracked != nil)
        }

        let first = displays[0]
        return DisplayChoice(display: first, reason: "using the first display \(first.id)" + requestedNote,
                             fellBack: tracked != nil)
    }
}

/// Collapses a burst of notifications into one action, `window` after the last of them.
///
/// Closing a lid on macOS 26 fires `didChangeScreenParameters` two or three times within a few
/// hundred milliseconds; restarting the stream for each of them leaves the picture black for
/// longer than it takes to come back. This only decides *when* the one action happens, so it is
/// small enough to test without a screen.
struct Debounce {
    let window: TimeInterval
    private(set) var lastEvent: Date?

    init(window: TimeInterval) { self.window = window }

    mutating func note(_ now: Date) { lastEvent = now }

    /// The moment the coalesced action is due.
    var deadline: Date? { lastEvent.map { $0.addingTimeInterval(window) } }

    /// Whether a timer firing at `now` belongs to the newest event. False means another event
    /// arrived behind it and the work is already scheduled again.
    func isCurrent(at now: Date) -> Bool {
        guard let last = lastEvent else { return false }
        return now >= last.addingTimeInterval(window)
    }

    mutating func reset() { lastEvent = nil }
}

/// The display set as a value that can be compared cheaply, once a second.
///
/// Why polling exists at all: `NSApplication.didChangeScreenParametersNotification` is posted by
/// NSApp's run loop (krd never runs one) and `CGDisplayRegisterReconfigurationCallback` is not
/// delivered to a process outside the Aqua session -- measured on macOS 26, a probe started over
/// ssh got neither, while the same probe under `NSApp.run()` got three notifications per
/// resolution change. A mirror that only recovers when launched from a GUI terminal is not the
/// product, so the callback stays (it is the fast path in the GUI case) and this fingerprint is
/// the backstop that works everywhere.
enum DisplaySet {
    /// Sorted by display id: the list's order is not a change, and comparing two lists of
    /// structs is cheap enough for 1 Hz.
    static func fingerprint(_ displays: [DisplayBox]) -> [DisplayBox] {
        displays.sorted { $0.id < $1.id }
    }

    static func differs(_ lhs: [DisplayBox], _ rhs: [DisplayBox]) -> Bool {
        fingerprint(lhs) != fingerprint(rhs)
    }
}
