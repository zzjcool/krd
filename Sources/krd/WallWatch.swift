import AppKit
import Foundation

/// The wall's world watcher: the events the system actually reports when the window list can move.
///
/// This is the trigger that replaced the 1 s enumeration (issue #141). It exists because the
/// *answer* to "did anything change?" is only worth paying for when the answer can be yes, and
/// AppKit already knows when that is:
///
/// - an app launched or quit (a regular app's windows can appear or vanish — `WindowOrder` filters
///   by `regularPIDs`, so this is exactly the set that can change the list's membership),
/// - an app was activated or deactivated (the list is front-to-back, so the *order* changes with
///   focus),
/// - an app was hidden or unhidden (`optionOnScreenOnly` drops a hidden app's windows),
/// - the active space changed (the on-screen set is per-space),
/// - the display configuration changed (`NSScreen.screens` and the stage's aspect).
///
/// A window that closes or opens inside an app that is *already* frontmost while the wall's
/// terminal sits behind it is the one case AppKit does not announce. Two things cover it, and both
/// are gated on `WallSource.fingerprint()` (issue #169 review):
///
/// - `wallClick` takes the fingerprint **itself**, before it hit-tests the point, with trigger
///   `.input` — so a click can never land on a window id the window server no longer has. (Nothing
///   about a click reaches this file: `WallWatch` only observes notifications; the resync is the
///   click's own, one fingerprint and, only if it moved, one enumeration.)
/// - Everything else is bounded by the fingerprint poll: `WallSource.pollInterval` (2.0 s) takes one
///   fingerprint and enumerates only when it moved, so a card this file's events missed is stale
///   for **at most 2.0 s + one paint** — 0.51 s of capture-and-paint measured (issue #169 gate), so
///   the honest bound is **~2.5 s**, and **3.0 s** when a second trigger lands mid-capture and is
///   painted by the follow-up paint (`WallSource.stalenessBound`). That bound is hard for any change
///   the fingerprint can see, and it sees
///   every membership change — the window count *and* the sum of window numbers, which a close plus
///   an open cannot cancel.
///
/// The alternative — a per-second enumeration that throws its answer away — is the bug this file
/// removes (issue #141: 1.24 ms median / 1.52 ms p95 of wall time, every second, to conclude
/// `unchanged`).
final class WallWatch {
    private var tokens: [NSObjectProtocol] = []

    /// `onWorldChange` runs on the main queue, coalesced: a launch posts several notifications in a
    /// row (activate + launch), and a window that is still being created when the first one lands
    /// must not be missed. The delay is the whole reason the refresh is not immediate.
    func start(coalescing delay: TimeInterval = 0.08, onWorldChange: @escaping () -> Void) {
        stop()
        var pending: DispatchWorkItem?
        let fire: () -> Void = {
            pending?.cancel()
            let work = DispatchWorkItem(block: onWorldChange)
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        // The fingerprint's cached halves: a launch/terminate is the only way the regular-pid set can
        // move, and screen parameters are the only way the display ids can. Dropping the caches here
        // is what lets the 2 s poll read both for free (`WallSource.invalidateFingerprint`).
        let invalidate: (Notification) -> Void = { _ in WallSource.invalidateFingerprint() }
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main,
                                               using: invalidate))
        }
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                // The activated app arrives *in the notification*, so the fingerprint's frontmost pid
                // is a pointer read here rather than a lookup on the 2 s poll — the cache can only be
                // stale for as long as it takes this notification to land. (Measured: the lookup was
                // 0.12 µs warm / ~9 µs cold, so this is correctness and tidiness, not the 2.7x.)
                if name == NSWorkspace.didActivateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication {
                    WallSource.noteActivation(app)
                }
                // `queue: .main` means this already runs on the main queue, so the work item below
                // is ordered after the notification that caused it.
                fire()
            })
        }
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                WallSource.invalidateFingerprint()
                fire()
            })
    }

    func stop() {
        let workspace = NSWorkspace.shared.notificationCenter
        for token in tokens { workspace.removeObserver(token); NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }

    deinit { stop() }
}
